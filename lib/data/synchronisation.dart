import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/models.dart';
import 'base_locale.dart';
import 'transmetteur.dart';

/// Le worker qui vide la file d'attente vers le serveur (CDC §14 à §17).
///
/// Trois verrous gouvernent tout :
/// - **pas de base persistee** → la file n'existe pas sur disque, rien a
///   transmettre (l'application continue en memoire) ;
/// - **`reseauDisponible == false`** → aucun appel, les evenements restent en
///   `PENDING` : une coupure de 4G ne perd jamais une donnee (§15, REQ-012) ;
/// - **chaque echec repousse** la prochaine tentative (backoff) au lieu de
///   harceler un serveur qui ne repond pas (REQ-013).
///
/// La boucle ne tourne que si [demarrer] est appele : les tests pilotent
/// [unePasse] a la main, sans minuterie.
class Synchronisation extends ChangeNotifier {
  Synchronisation({
    required this.base,
    required this.transmetteur,
    this.entretien = const Duration(seconds: 5),
    void Function(String message)? surMessage,
  }) : _surMessage = surMessage;

  final BaseLocale base;
  final Transmetteur transmetteur;

  /// Cadence de la boucle de fond (reprise permanente, §24).
  final Duration entretien;

  final void Function(String)? _surMessage;

  /// Etat de la 4G, pilote par la session (§15).
  bool reseauDisponible = true;

  /// Dernier accusé de reception : la « Dernière sync » de §21.
  DateTime? derniereSynchro;

  /// Evenements valides depuis le demarrage de l'application.
  int totalSynchronises = 0;

  Timer? _minuterie;
  bool _enCours = false;
  String? _dernierAvis;

  /// Empreinte de la derniere affectation ecrite : evite de reecrire la
  /// table et de renvoyer le meme message toutes les cinq secondes.
  String? _signatureAffectation;

  /// Lance la boucle de fond. Sans base persistee, il n'y a rien a vider :
  /// on ne cree pas de minuterie qui tourne pour rien.
  void demarrer() {
    if (!base.estPersistee || _minuterie != null) return;
    _minuterie = Timer.periodic(entretien, (_) => unePasse());
  }

  void arreter() {
    _minuterie?.cancel();
    _minuterie = null;
  }

  /// La boucle de fond tourne-t-elle ? (badge 4G : rougement si elle n'a
  /// jamais ete lancee).
  bool get actif => _minuterie != null;

  /// Dernier retour du serveur (badge 4G, §21) : `null` tant que la
  /// synchronisation n'a rien tente.
  bool? get serveurRepondu => transmetteur.serveurRepondu;

  /// Une vague d'envois : lit ce qui est due, pousse, replanifie le reste.
  ///
  /// Renvoie le nombre d'evenements valides par cette vague.
  Future<int> unePasse() async {
    // Deux minuteries ne doivent jamais se chevaucher : une passe peut durer
    // plus longtemps que [entretien] quand le reseau traîne.
    if (_enCours) return 0;
    _enCours = true;
    try {
      return await _passe();
    } catch (e) {
      base.journaliser('SYNCHRO ANOMALIE $e');
      _dire('Synchro interrompue - erreur technique');
      return 0;
    } finally {
      _enCours = false;
    }
  }

  Future<int> _passe() async {
    if (!reseauDisponible) {
      _dire('4G hors ligne - ${base.nombreEnAttente} evenement(s) conserve(s)');
      return 0;
    }

    final DateTime maintenant = DateTime.now();
    // Vu dans cette vague, pour ne jamais reessayer un echec sur-le-champ.
    final Set<String> dejaVus = <String>{};
    int valides = 0;
    int essais = 0;

    // Jusqu'a dix vagues : la file peut grossir pendant la synchro (ecriture
    // metier en cours), sans pour autant tourner a l'infini.
    for (int vague = 0; vague < 10; vague++) {
      final List<Map<String, Object?>> candidates = await base.aTransmettre(
        limite: 20,
        maintenant: maintenant,
      );
      final List<Map<String, Object?>> lot = candidates
          .where((Map<String, Object?> ligne) =>
              !dejaVus.contains(ligne['event_id']! as String))
          .toList();
      if (lot.isEmpty) break;

      for (final Map<String, Object?> ligne in lot) {
        final String id = ligne['event_id']! as String;
        dejaVus.add(id);
        essais++;
        // `ligne` est l'instantané d'avant `marquerEnCours` : la tentative
        // qui vient d'etre comptee en base est donc +1.
        final int tentatives = ((ligne['tentatives'] as int?) ?? 0) + 1;

        await base.marquerEnCours(id);
        final ReponseServeur reponse =
            await transmetteur.envoyer(Enveloppe.depuisLigne(ligne));

        if (reponse.accepte) {
          await base.marquerSynchronise(id);
          valides++;
          totalSynchronises++;
          derniereSynchro = DateTime.now();
          base.journaliser(
            'SYNCHRO $id ${reponse.doublon ? 'DOUBLON' : 'ACK'} ${reponse.code}',
          );
        } else {
          await base.remettreEnAttente(
            id,
            nouvelleTentative: _prochaine(DateTime.now(), tentatives),
          );
          base.journaliser(
            'SYNCHRO $id ECHEC '
            '${reponse.code == 0 ? (reponse.erreur ?? 'reseau') : reponse.code}',
          );
        }
      }
    }

    if (valides > 0) {
      _dire(
        'Synchro serveur - $valides evenement(s) valide(s), '
        '${base.nombreEnAttente} en attente',
      );
    } else if (essais > 0) {
      _dire(
        'Serveur injoignable - ${base.nombreEnAttente} evenement(s) conserve(s)',
      );
    }
    // L'affectation n'a aucun lien avec la file : elle est lue a chaque
    // passe, meme quand rien n'est parti, car l'ecran DT en depend pour
    // savoir ou aller.
    await unePasseAffectation();
    // Les referentiels metier (profils, equipements, familles DT) viennent
    // du serveur et sont poses localement dans une transaction atomique.
    await unePasseReferentiels();
    // Idem pour les blasts et cartes disponibles pour le spotter.
    await unePasseBlasts();
    // Canal Boss -> tablette : les nouveaux messages depuis le dernier id
    // connu, pousses dans la zone de notifications de l'interface.
    await unePasseNotifications();
    notifyListeners();
    return valides;
  }

  /// Télécharge et remplace les référentiels locaux depuis le snapshot serveur.
  /// Une erreur ou un snapshot invalide conserve intégralement les valeurs
  /// locales précédentes. La synchronisation ne déduit rien depuis le code.
  Future<void> unePasseReferentiels({bool forcer = false}) async {
    if (!reseauDisponible && !forcer) return;
    final ReferentielsServeur? snapshot =
        await transmetteur.lireReferentiels();
    if (snapshot == null) {
      _dire('Referentiels : aucune reponse exploitable du serveur');
      return;
    }
    try {
      await base.appliquerReferentiels(snapshot);
    } on Object catch (e) {
      base.journaliser('REFERENTIELS refuses : $e');
      // Le motif est repris tel quel : sans lui, l'ecran reste bloque sur
      // « Aucun profil configure » sans que personne ne sache pourquoi.
      _dire('Referentiels refuse par l\'app : $e');
      return;
    }
    _dire(
      'Referentiels serveur - ${snapshot.profils.length} profil(s), '
      '${snapshot.equipements.length} equipement(s), '
      '${snapshot.typesDT.length} famille(s) DT',
    );
    base.journaliser(
      'REFERENTIELS recus: ${snapshot.profils.length} profils, '
      '${snapshot.equipements.length} equipements, '
      '${snapshot.typesDT.length} familles DT',
    );
    notifyListeners();
  }

  /// Lit les notifications du serveur posterieures au dernier id connu et
  /// les pose en base. Chaque nouveau message : bandeau rouge plein cadre
  /// (ordre du bureau) + message technique dans le ticker. Si la session
  /// porte un relais local (DT excavatrice), le message est re-diffuse aux
  /// clients presents dans son rayon — c'est la chaine Boss -> serveur ->
  /// DT -> spotter qui complete la descente HTTP directe.
  Future<void> unePasseNotifications() async {
    if (!reseauDisponible) return;
    final List<NotificationServeur>? recues = await transmetteur
        .lireNotifications(depuis: base.derniereIdNotification);
    if (recues == null || recues.isEmpty) return;

    final int ecrits = base.recevoirNotifications(recues);
    for (final NotificationServeur n in recues) {
      if (n.id <= base.derniereIdNotification) continue;
      // La session fait le reste : bandeau rouge + ticker + relais local.
      _surMessage?.call('BOSS#${n.id}#${n.profil}#${n.message}');
    }
    if (ecrits > 0) {
      base.journaliser('NOTIFICATIONS $ecrits nouveau(x) message(s) du serveur');
      notifyListeners();
    }
  }

  /// Lit la liste des blasts proposee par le serveur et l'ecrit dans la base.
  ///
  /// `null` rendu par le transmetteur = rien a changer (defaut, reseau) : la
  /// liste locale n'est jamais alteree par une erreur de passage (REQ-012).
  /// Apres ecriture, les plans encore en URL serveur sont telecharges vers
  /// des fichiers locaux — c'est ce qui rend les cartes consultables hors
  /// ligne, le JPG suivant la base et non le reseau.
  Future<void> unePasseBlasts() async {
    if (!reseauDisponible) return;
    final List<BlastServeur>? liste = await transmetteur.lireBlasts();
    if (liste == null) {
      // null = le transmetteur a refuse de servir (token invalide, 4xx/5xx).
      // On le journalise : un token mal aligne ne fait plus silence.
      base.journaliser('BLASTS serveur injoignable (token ou reseau KO)');
      return;
    }
    if (liste.isEmpty) {
      base.journaliser('BLASTS serveur : liste vide recue');
      return;
    }

    final int ecrits = base.recevoirBlasts(liste);
    if (ecrits > 0) {
      _dire(
        'Blasts recus du serveur - $ecrits mise(s) a jour, '
        '${base.blasts.length} blast(s) en local',
      );
      notifyListeners();
    }

    // Plans manquants : on telecharge le plan de CHAQUE carte du blast (une
    // par RL). Un blast a plusieurs RL (ex. 113 = flitch 260 + 262.5) a un
    // plan different par RL ; ne telecharger que `serveur.planUrl` laisserait
    // les autres RL sans image.
    for (final BlastServeur serveur in liste) {
      if (serveur.planUrl.isEmpty) continue;
      final Blast? blast = base.parNumero(serveur.numero);
      if (blast == null) continue;

      // Table carte -> URL : on part de l'URL globale, puis on ajoute les
      // URL par carte quand le serveur les fournit.
      final Map<String, String> urls = <String, String>{};
      if (serveur.planUrl.isNotEmpty) {
        urls[serveur.carte] = serveur.planUrl;
      }
      serveur.planUrlParCarte.forEach((String carte, String url) {
        if (url.isEmpty) return;
        urls[carte] = url;
        // Redondance volontaire : la table memoire de la base est aussi
        // alimentee ici, pour que `planPourCarte` connaisse l'URL de CE RL
        // meme si `recevoirBlasts` a ete court-circuite (blast deja connu).
        base.poserUrlPlan(carte, url);
      });

      for (final MapEntry<String, String> e in urls.entries) {
        final String carte = e.key;
        final String url = e.value;
        // Deja telecharge pour cette carte : rien a refaire.
        final String? dejaLocal = base.planDe(carte);
        if (dejaLocal != null && dejaLocal.isNotEmpty) continue;

        final Uint8List? octets = await transmetteur.telechargerPlan(url);
        if (octets == null || octets.isEmpty) continue;
        final String? chemin = await _ecrirePlanCarte(carte, octets);
        if (chemin == null) continue;
        base.poserPlanLocal(carte, chemin);
        _dire('Plan telecharge - carte $carte du blast ${serveur.numero}');
        notifyListeners();
      }
    }
  }

  /// Ecrit les octets du plan d'une carte dans un fichier local.
  ///
  /// Le nom de fichier est stable (code de carte) : une re-telecharge ecrase
  /// le meme fichier au lieu d'accumuler des copies. L'extension suit le
  /// type reel des octets (PNG ou GIF possible dans le dossier Drive).
  Future<String?> _ecrirePlanCarte(String carte, Uint8List octets) async {
    if (octets.isEmpty) return null;
    try {
      final Directory dossier = await getApplicationDocumentsDirectory();
      final String ext = _extensionImage(octets);
      final String chemin =
          '${dossier.path}${Platform.pathSeparator}plan_$carte.$ext';
      final File fichier = File(chemin);
      await fichier.writeAsBytes(octets, flush: true);
      return chemin;
    } catch (e) {
      base.journaliser('PLAN $carte ECHEC $e');
      return null;
    }
  }

  /// Devine l'extension depuis les octets (signature du fichier).
  static String _extensionImage(Uint8List octets) {
    if (octets.length >= 4) {
      // PNG : 89 50 4E 47
      if (octets[0] == 0x89 && octets[1] == 0x50 &&
          octets[2] == 0x4E && octets[3] == 0x47) {
        return 'png';
      }
      // GIF : 47 49 46 38
      if (octets[0] == 0x47 && octets[1] == 0x49 &&
          octets[2] == 0x46 && octets[3] == 0x38) {
        return 'gif';
      }
    }
    return 'jpg';
  }

  /// Lit l'affectation choisie et validee par le serveur (destination,
  /// dumping area, mission) et la pose en base.
  ///
  /// `null` rendu par le transmetteur = on ne change rien : la derniere
  /// valeur connue reste affichee, une erreur de reseau n'efface jamais une
  /// destination (REQ-012). Un contenu identique a celui deja en base n'est
  /// pas reecrit.
  Future<void> unePasseAffectation() async {
    if (!reseauDisponible) return;
    final Affectation? affectation = await transmetteur.lireAffectation();
    if (affectation == null || affectation.champs.isEmpty) return;

    final String signature = affectation.champs.entries
        .map((MapEntry<String, String> e) => '${e.key}=${e.value}')
        .join(' ');
    if (signature == _signatureAffectation) return;

    await base.enregistrerAffectation(
      affectation.champs,
      horodatage: affectation.valideLe,
    );
    _signatureAffectation = signature;
    _dire('Affectation serveur - $signature');
    notifyListeners();
  }

  /// Backoff exponentiel plafonne : 5 s, 10 s, 20 s ... 15 min (§14).
  static DateTime _prochaine(DateTime depuis, int tentatives) {
    final int exposant = (tentatives - 1).clamp(0, 10).toInt();
    final int brut = 5 * (1 << exposant);
    return depuis.add(Duration(seconds: brut > 900 ? 900 : brut));
  }

  /// Une notification, seulement si elle change : la boucle tourne toutes les
  /// cinq secondes et personne n'a envie du meme message en boucle.
  void _dire(String message) {
    if (_dernierAvis == message) return;
    _dernierAvis = message;
    _surMessage?.call(message);
  }

  @override
  void dispose() {
    arreter();
    super.dispose();
  }
}

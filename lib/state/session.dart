import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

import '../communication/ble/ble_gateway.dart';
import '../communication/ble/ble_protocole.dart';
import '../communication/ble/permissions_ble.dart';
import '../communication/ble/transport_ble.dart';
import '../communication/ble/transport_central.dart';
import '../communication/ble/transport_natif.dart';
import '../communication/ble/transport_peripherique.dart';
import '../communication/position/service_position.dart';
import '../communication/alertes/alerter.dart';
import '../communication/position/detection_ecart.dart';
import '../communication/position/progression.dart';
import '../communication/position/session_perle.dart';
import '../communication/wifi/transport_tcp.dart';
import '../communication/wifi/transport_wifi.dart';
import '../communication/wifi/wifi_direct.dart';
import '../communication/wifi/wifi_gateway.dart';
import '../communication/gnss/parseur_nmea.dart';
import '../communication/xbee/transport_xbee.dart';
import '../data/base_locale.dart';
import '../data/synchronisation.dart';
import '../data/transmetteur.dart';
import '../models/models.dart';
import 'etat_couche.dart';

/// Etat partage de l'application.
///
/// La boucle de synchro simule ici le serveur P2P permanent qui tourne en
/// tache de fond sur la tablette de l'excavatrice (point d'acces Master) :
/// chaque tick met a jour les compteurs et diffuse une notification.
///
/// La synchro **serveur** (CDC Â§14) est un sujet distinct : c'est
/// [synchro], qui vide la file `evenements` des que la 4G revient.
class Session extends ChangeNotifier {
  Session({
    AlerteMetier? alerter,
    BaseLocale? base,
    Transmetteur? transmetteur,
  })  : alerter = alerter ?? AlerteSysteme(),
        base = base ?? BaseLocale() {
    _seedNotifications();
    synchro = Synchronisation(
      base: this.base,
      // L'URL et le jeton sont lus dans `meta` a chaque envoi : changer la
      // configuration ne demande aucun redemarrage.
      transmetteur: transmetteur ?? TransmetteurHttp(meta: this.base.meta),
      surMessage: _messageSynchro,
    );
    // RELAIS VERS L'UI : sans cette ecoute, `synchro.notifyListeners()`
    // (appele apres chaque passe de referentiels) ne reveillait aucun
    // listener — la session, elle, n'en etait pas informee. Resultat : les
    // menus Famille / Identifiant de la connexion restaient vides alors que
    // la base contenait bien les 25 engins (observe 22/10).
    synchro.addListener(_surSynchro);
  }

  /// La synchro a change d'etat : l'UI (login, badges de synchro) se
  /// reconstruit. Un seul point de relais, la session reste la seule
  /// source d'ecoute pour les ecrans.
  void _surSynchro() {
    if (_actif) notifyListeners();
  }

  /// Messages du worker de synchro. Les notifications Boss arrivent en
  /// `BOSS#id#profil#message` : elles declenchent le bandeau rouge et le
  /// relais local (DT -> excavatrice -> spotter) en plus du ticker. Tout le
  /// reste est un simple evenement technique a faire defiler.
  void _messageSynchro(String message) {
    if (message.startsWith('BOSS#')) {
      final List<String> morceaux = message.split('#');
      if (morceaux.length >= 4) {
        unawaited(recevoirNotificationLocale(<String, Object?>{
          'id': morceaux[1],
          'profil': morceaux[2],
          'message': morceaux.sublist(3).join('#'),
        }));
        return;
      }
    }
    push(message);
  }

  /// Canal sonore + vibratoire de l'alerte hors-parcours : injectable pour
  /// que les tests comptent les declenchements au lieu de vibrer.
  final AlerteMetier alerter;

  /// Comparateur de position au parcours vers la dumping area (option B) :
  /// pures mathematiques, il ne connait ni le reseau ni le materiel.
  final DetecteurEcart detecteurEcart = DetecteurEcart();

  /// Calculateur de progression le long du meme parcours (CDC Â§4.6) : a
  /// chaque mesure GNSS, la position est projetee sur la polyline recue du
  /// serveur. C'est la valeur reelle que lisent la barre de trajet et la
  /// carte de l'ecran DT (plus aucune simulation).
  final CalculateurProgression progression = CalculateurProgression();

  /// Base de donnees locale. Les listes deroulantes de l'ecran spotter lisent
  /// dedans, et aucune modification ne la contourne. Injectable pour que les
  /// tests y injectent des blasts de demo (`BaseLocale.blastsDemo()`).
  final BaseLocale base;

  /// Worker de synchro serveur (CDC Â§14) : vide la file `evenements`.
  ///
  /// Construit une seule fois avec la session ; demarre a la connexion, s'arrete
  /// a la deconnexion. Les tests le pilotent par [Synchronisation.unePasse].
  late final Synchronisation synchro;

  /// Ouvre le fichier local (CDC Â§13) et recharge les donnees du disque.
  ///
  /// Appelee par le splash : echoue silencieusement en Â« memoire seule Â» si le
  /// fichier est inaccessible, l'application ne s'arrete jamais la-dessus.
  ///
  /// Mode demo supprime (demande du 21/10) : aucun scenario fictif, le GPS
  /// est toujours le recepteur reel.
  Future<void> ouvrirBase() async {
    await base.ouvrir();
    // Chaque ligne de journal reseau repeint l'interface (supervision).
    // Le relais est pose APRES `ouvrir()` : c'est la que la base s'inscrit
    // dans la liste des instances notifiees.
    base.surJournalReseau = (String _) => notifyListeners();
    // Plans deja telecharges lors d'une session precedente : sans ce scan,
    // ils seraient oublies au redemarrage et l'ecran afficherait de nouveau
    // l'URL reseau (ou le plan de la premiere carte) pour chaque RL.
    await base.chargerPlansLocaux();
    demarrerSurveillanceReseau();
    // PremiÃ¨re alimentation des listes de login (profils, Ã©quipements, DT)
    // avant d'afficher l'Ã©cran de connexion. Hors rÃ©seau, la base locale
    // existante est conservÃ©e et l'utilisateur verra l'Ã©tat d'attente.
    await synchro.unePasseReferentiels(forcer: true);
    push(
      base.estPersistee
          ? 'Base locale ouverte - ecritures sauvegardees sur disque'
          : 'Base locale indisponible - fonctionnement en memoire',
    );
    // Selection par defaut : le premier blast recu du serveur, s'il y en a
    // un. Sans blast (production neuve, attente serveur) la selection reste
    // vide et l'ecran l'affiche comme tel.
    if (base.numerosBlast.isNotEmpty) {
      selectionnerBlast(base.numerosBlast.first);
    }
    // File nettoyee DES L'OUVERTURE, avant tout envoi : les mesures GPS
    // prises avant le login portent un `source_device` vide et le serveur les
    // refuse. Sans cet appel, elles restaient en PENDING a vie et gonflaient
    // le compteur d'attente affiche a l'operateur (constat du 27/10).
    await base.purgerEvenementsOrphelins();
    // Les seuils de detection et le GPS se parametrent dans l'ecran
    // Parametres : lus ici une premiere fois, relus par
    // [rechargerParametres] a chaque changement.
    _intervalleGps = _dureeMeta('intervalle_gps_s', 5);
    _filtreGps = _doubleMeta('filtre_distance_gps_m', 5);
    rechargerParametres();
    // Le GPS (Â§5) part avec la base : ses mesures finissent dans la meme
    // file d'evenements. Sur desktop sans capteur, le service reste
    // silencieux sans jamais planter. L'abonnement aux mesures se pose
    // AVANT le demarrage : la premiere mesure ne peut pas passer a cote.
    //
    // EXCEPTION SPOTTER : sa tablette n'embarque aucun recepteur GNSS. Faire
    // demarrer le service produirait des `GPS_UPDATE` fantomes dans la file
    // d'evenements (compteur Â« en attente Â» gonfle par des mesures que
    // l'utilisateur n'a jamais prises).
    final bool gpsUtile = !BaseLocale.estSpotter(profile?.roleCdc ?? '');
    if (gpsUtile) {
      servicePosition = ServicePosition(
        base: base,
        // La source vient du reglage `source_gps`.
        // Â« GPS GNSS Â» = recepteur externe, seul releve exploitable ;
        // Â« GPS tablette Â» = capteur du device, affiche mais signale.
        fournisseur: GpsReel(
                intervalle: _intervalleGps,
                filtreDistance: _filtreGps,
                source: choixGps.source,
              ),
        intervalle: _intervalleGps,
        filtreDistance: _filtreGps,
      );
      _subMesures ??= servicePosition!.mesures.listen(traiterMesure);
      // FLUX DE MAINTIEN : la meme position, republiee a cadence fixe.
      //
      // Le filtre de distance (5 m) bloque TOUT quand la tablette est posee :
      // Android cesse alors de livrer la moindre position, et la session
      // perle restait a « 0 position(s) » sur l'ecran Excavator, Xmoy/Ymoy/Zmoy
      // vides, alors que la connexion au DT etait bien ouverte (27/10).
      //
      // On ne touche NI a la file d'evenements (aucun GPS_UPDATE en double)
      // NI a la detection d'ecart : seul l'accumulateur de perle est alimente.
      _subMaintien ??= servicePosition!.maintien.listen(feederPerle);
      servicePosition!.demarrer();
    }
  }

  /// Service de position du device (CDC Â§5) : demarre a l'ouverture de la
  /// base, arrete a la fermeture de la session.
  ServicePosition? servicePosition;

  /// Abonnement au flux de maintien : position republiee a cadence fixe,
  /// pour que la moyenne de perle tourne meme a l'arret.
  StreamSubscription<PositionTerrain>? _subMaintien;

  /// Transport BLE natif (autoConnect), cree une fois et reutilise.
  ///
  /// On le garde en champ pour que la machine d'etat conserve son appairage
  /// et son lien entre deux appels a `demarrerCouchesLocales` (Parametres,
  /// reconnexions). Le recreer a chaque passage perdrait l'adresse memorisee
  /// et remettrait la pile GATT a zero.
  late final TransportBleNatif _transportNatif = TransportBleNatif();

  /// Transport BLE natif expose a l'interface (etat, appairage).
  TransportBleNatif get transportNatif => _transportNatif;

  StreamSubscription<PositionTerrain>? _subMesures;

  /// Evenements en attente de transmission vers le serveur (CDC Â§14, Â§21).
  int get enAttente => base.nombreEnAttente;

  /// Profil de la session, lu dans `base.profils()` au moment de la connexion.
  Profil? profile;
  String deviceId = '';
  String deviceName = '';
  bool masterConnected = false;

  /// Etat de la 4G (Â§15). Une coupure ne perd rien : elle arrete seulement
  /// les envois, la file reste en place et reprend seule au retablissement.
  bool get gsmOnline => synchro.reseauDisponible;

  set gsmOnline(bool valeur) {
    if (gsmOnline == valeur) return;
    synchro.reseauDisponible = valeur;
    if (valeur) {
      push('4G retablie - reprise de la synchronisation serveur');
      // Une passe immÃ©diate au rÃ©tablissement (Â§15) : la nuÃ©e est animÃ©e
      // pendant l'Ã©change tant qu'il reste quelque chose Ã  vider.
      unawaited(_passeAvecAnimation());
    } else {
      push('4G perdue - les donnees restent en locale');
      // La nuÃ©e retombe : plus rien ne circule vers le serveur.
      synchroActive = false;
    }
    notifyListeners();
  }

  /// Vrai pendant un Ã©change effectif avec le serveur (Â§14) : la nuÃ©e
  /// ([SyncCloudIcon]) s'anime tant que la file PENDING n'est pas vide.
  bool synchroActive = false;

  /// Une passe de synchro avec animation de la nuÃ©e : active tant que des
  /// Ã©vÃ©nements restent Ã  transmettre, Ã©teinte dÃ¨s que la file est vide.
  Future<void> _passeAvecAnimation() async {
    if (!base.estPersistee) return;
    synchroActive = true;
    notifyListeners();
    try {
      await synchro.unePasse();
    } finally {
      synchroActive = base.nombreEnAttente > 0;
      notifyListeners();
    }
  }

  /// Synchro manuelle (nuage du bandeau bas, Â§14) : relance une passe
  /// complete â€” evenements sortants PUIS lectures entrantes (referentiels,
  /// blasts, affectation, notifications). Deux appuis rapproches ne
  /// multiplient pas les passes : si une passe tourne deja, l'appui est
  /// simplement ignore â€” la file et la nuÃ©e font foi.
  Future<void> synchroniserManuellement() async {
    if (synchroActive) return;
    if (!gsmOnline) {
      push('Synchronisation impossible - serveur injoignable (4G/Wi-Fi absent)');
      notifyListeners();
      return;
    }
    push('Synchronisation demandee...');
    synchroActive = true;
    notifyListeners();
    try {
      await synchro.unePasse();
      await synchro.unePasseReferentiels(forcer: true);
      await synchro.unePasseBlasts();
      await synchro.unePasseAffectation();
      await synchro.unePasseNotifications();
    } finally {
      synchroActive = base.nombreEnAttente > 0;
      notifyListeners();
    }
  }

  // ---------------------------------------------------------- reseau reel

  /// Abonnement a l'etat reel du reseau (connectivity_plus). Le badge 4G et
  /// la synchro serveur lisent la meme source : plus rien de simule.
  final Connectivity _apiReseau = Connectivity();
  StreamSubscription<List<ConnectivityResult>>? _subConnectivite;

  /// Dernier etat lu chez le systeme, vide tant que la surveillance n'a pas
  /// rendu son premier resultat (badge Wi-Fi : Â« pas demarre Â»).
  List<ConnectivityResult> _connectivite = const <ConnectivityResult>[];

  /// Etat reseau courant, tel que lu chez le systeme.
  List<ConnectivityResult> get connectivite => _connectivite;

  /// Demarre l'ecoute de l'etat reseau du systeme : toute variation (Wi-Fi
  /// coupe, 4G perdue, retour a la portee) met a jour le badge et relance la
  /// synchro serveur. Sans cette ecoute, [gsmOnline] resterait au booleen de
  /// test initial.
  void demarrerSurveillanceReseau() {
    _subConnectivite ??= _apiReseau.onConnectivityChanged.listen(
      majConnectivite,
      onError: (Object _) {
        // Sur une plateforme ou connectivity_plus n'est pas implemente, on
        // ne plante pas : le badge reste dans son dernier etat connu.
      },
    );
    // Le stream ne se declenche qu'a la premiere variation : sans cet appel
    // initial, les badges resteraient dans l'etat Â« pas demarre Â» jusqu'a ce
    // que le reseau change reellement.
    _apiReseau
        .checkConnectivity()
        .then<void>(majConnectivite, onError: (Object _) {});
    // Route serveur des le DEMARRAGE, pas seulement apres connexion : quand
    // l'operateur a partage son reseau (AndroidShare_xxx), le Wi-Fi local
    // devient la route par defaut et il n'a pas d'Internet â€” la sonde 4G
    // echouait toutes les 5 s AVANT le login (Â« aucun profil Â», synchro
    // infinie). Cette route ne touche que le trafic hors sous-rÃ©seau direct,
    // donc le TCP de l'excavatrice reste joignable.
    unawaited(WifiDirect.forcerCellulaire());
    // Premiere lecture : sans elle, le badge attendrait 3 s avant d'etre juste.
    unawaited(_lireReseauReel());
    // Filet de securite : sur Android, le flux de `connectivity_plus`
    // n'emet pas toujours quand la 4G change alors qu'un Wi-Fi est
    // prioritaire (cas du point d'acces local). Le badge ne bougeait alors
    // qu'au redemarrage de l'application. On relit donc l'etat du systeme a
    // intervalle fixe : c'est peu couteux et toujours juste.
    _minuterieReseau ??= Timer.periodic(
      // 3 s (demande du 26/10) : le badge doit suivre une coupure de 4G
      // pendant la session, pas seulement au demarrage. La sonde ouvre une
      // vraie socket, d'ou l'intervalle non nul ; 3 s reste acceptable et
      // c'est la cadence retenue avec l'operateur.
      const Duration(seconds: 3),
      (_) => _lireReseauReel(),
    );
  }

  /// Vrai quand une sonde 4G a repondu au moins une fois.
  ///
  /// Sans ce drapeau, le badge gardait son dernier etat vert indefiniment :
  /// une sonde qui n'aboutit pas ne changeait rien, et l'ecran affirmait
  /// Â« 4G Â» alors que la data etait coupee. Un etat inconnu doit se voir.
  bool _sonde4GRecue = false;

  /// Lit l'etat reseau chez Android et met a jour la session.
  ///
  /// Deux sources, volontairement : `connectivity_plus` pour le Wi-Fi, et le
  /// **canal natif** pour la 4G. Le plugin perd la 4G derriere un Wi-Fi en
  /// portail captif â€” c'est ce qui rendait le badge juste sur le DT (sans
  /// Wi-Fi) et faux sur le spotter.
  /// Vrai pendant qu'une lecture reseau est en cours.
  ///
  /// La minuterie passe toutes les 3 s ; une sonde dont la socket expire
  /// peut durer plus longtemps. Sans ce verrou, deux mesures se chevauchaient
  /// et la PLUS ANCIENNE ecrasait la plus recente a son retour — le badge
  /// sautait alors en arriere et paraissait fige (constat du 26/10).
  bool _lectureReseauEnCours = false;

  Future<void> _lireReseauReel() async {
    if (!_actif) return;
    if (_lectureReseauEnCours) return;
    _lectureReseauEnCours = true;
    try {
      await _lireReseauReelInterne();
    } finally {
      _lectureReseauEnCours = false;
    }
  }

  Future<void> _lireReseauReelInterne() async {
    ({bool actif, bool present})? cell;
    try {
      cell = await WifiDirect.etatCellulaire();
    } catch (e) {
      // Sans ce journal, une erreur du canal natif etait avalee en silence :
      // on croyait la sonde branchee alors qu'elle n'etait jamais appelee.
      base.journaliser('RESEAU sonde : echec canal natif ($e)');
    }
    final bool avantSonde = _sonde4GRecue;
    final bool avantJoignable = _derniereSondeJoignable;
    if (cell == null) {
      // Canal indisponible : on ne touche pas a `gsmOnline`, mais on marque
      // la mesure comme perimee. `etat4G` affichera orange, jamais vert
      // sur une valeur ancienne.
      _sonde4GRecue = false;
      if (avantSonde) notifyListeners();
      return;
    }
    _sonde4GRecue = true;
    // `present` et non `actif` : la 4G compte des qu'elle existe, meme si un
    // Wi-Fi la masque comme route par defaut. C'est elle qui porte la synchro
    // serveur grace a `RouteReseau`.
    final bool gsm = cell.present;
    _derniereSondeJoignable = gsm;
    // `gsmOnline` est un ALIAS de `synchro.reseauDisponible` : son setter sort
    // sans rien signaler quand la valeur est inchangee. Un badge qui n'ecoute
    // que lui restait donc FIGE (constat du 26/10 : la 4G passait de verte a
    // coupee sans que le voyant bouge, y compris apres modification pendant
    // la session). Le badge lit desormais `_derniereSondeJoignable`, et on
    // notifie sur CHAQUE mesure dont l'etat differe de la precedente.
    if (gsm != avantJoignable || !avantSonde) notifyListeners();
    gsmOnline = gsm;
    // Ne journaliser QUE le CHANGEMENT d'etat.
    //
    // La sonde tourne toutes les 3 s : ecrire une ligne a chaque mesure
    // produisait des centaines de lignes IDENTIQUES qui noyaient tout le
    // reste du journal — les lignes BLE (handshake, envoi, ACK) etaient
    // chassees avant d'avoir ete lues. C'est la vraie raison du « le journal
    // ne defile pas » constate le 27/10 : il defilait, mais avec du bruit.
    if (!avantSonde || gsm != avantJoignable) {
      base.journaliser(
        'RESEAU sonde 4G : ${gsm ? 'joignable' : 'injoignable'}',
      );
    }
    // Le Wi-Fi reste lu par le plugin : lui ne perd rien.
    try {
      majConnectivite(await _apiReseau.checkConnectivity());
    } catch (_) {
      // Plateforme sans plugin : l'etat cellulaire suffit.
    }
  }

  /// Resultat de la derniere sonde cellulaire aboutie.
  ///
  /// Distinct de [gsmOnline] : celui-ci reflete `synchro.reseauDisponible`,
  /// qui ne bouge qu'aux transitions et sert a arreter/relancer la boucle de
  /// synchro. Le badge 4G, lui, doit refleter **chaque** mesure.
  bool _derniereSondeJoignable = false;

  /// Vrai si la derniere sonde cellulaire a abouti (une mesure fraiche existe).
  bool get sonde4GFraiche => _sonde4GRecue;

  /// Relecture periodique de l'etat reseau (voir [demarrerSurveillanceReseau]).
  Timer? _minuterieReseau;

  void arreterSurveillanceReseau() {
    _subConnectivite?.cancel();
    _subConnectivite = null;
    _minuterieReseau?.cancel();
    _minuterieReseau = null;
  }

  /// Applique un etat reseau lu chez le systeme (ecouteur et tests).
  ///
  /// Seule porte d'entree de la realite reseau dans la session : elle
  /// alimente le badge Wi-Fi ([etatWifiDevice]) et la 4G ([gsmOnline]).
  @visibleForTesting
  void majConnectivite(List<ConnectivityResult> resultats) {
    _connectivite = List<ConnectivityResult>.unmodifiable(resultats);
    // Le badge s'appelle **4G** : il ne reflete QUE la radio cellulaire.
    //
    // Deux erreurs successives l'ont rendu menteur :
    //  - compter `wifi` comme Â« en ligne Â» affichait du vert sur le point
    //    d'acces de l'excavatrice, qui n'a pas d'Internet ;
    //  - compter un Wi-Fi de site *avec* Internet gardait le vert apres
    //    coupure de la donnee mobile, puisque le Wi-Fi repondait encore.
    // Si l'operateur coupe la 4G, le voyant 4G doit passer au rouge, point.
    // Une autre voie eventuelle est une information du badge Wi-Fi, pas de
    // celui-ci.
    // La 4G n'est PAS lue ici : le canal natif (`_lireReseauReel`) en est la
    // seule source. Ce plugin perd la 4G derriere un Wi-Fi en portail
    // captif, ce qui rendait le badge juste sur le DT (sans Wi-Fi) et faux
    // sur le spotter.
    notifyListeners();
  }

  // ---------------------------------------------------------- etats (badges)

  /// Badge Wi-Fi : lien vers le point d'acces Master (CDC Â§20.1).
  ///
  /// Rouge tant que la surveillance n'a rien lu ou que le Wi-Fi du device
  /// est absent (pas demarre / aucun retour), orange des que le radio est
  /// la sans session, vert une fois la session posee dessus.
  EtatCouche get etatWifiDevice {
    if (_connectivite.isEmpty) return EtatCouche.arret;
    final bool radio = _connectivite.any(
      (ConnectivityResult r) =>
          r == ConnectivityResult.wifi || r == ConnectivityResult.ethernet,
    );
    if (!radio) return EtatCouche.arret;
    return masterConnected ? EtatCouche.connecte : EtatCouche.recherche;
  }

  /// Badge GPS (Â§5) : le recepteur externe branche en USB-C est-il lu ?
  ///
  /// Vert des que le service de position produit des mesures (derniere
  /// mesure recue), orange tant que le service tourne sans avoir rien rendu
  /// (acquisition en cours, GPS pas encore fixe), rouge si le service est
  /// arrete ou n'a jamais pu s'abonner (capteur absent, permission refusee).
  EtatCouche get etatGps {
    final ServicePosition? service = servicePosition;
    if (service == null || !service.actif) return EtatCouche.arret;
    final PositionTerrain? derniere = service.derniere;
    if (derniere == null) return EtatCouche.recherche;
    // Vert UNIQUEMENT sur un recepteur externe. Le capteur interne de la
    // tablette rend une position qui peut venir du Wi-Fi ou du reseau
    // mobile : la presenter en vert laisserait croire a un releve de site
    // fiable, alors qu'elle peut etre fausse de plusieurs centaines de
    // metres. Orange = mesure presente mais non exploitable.
    return derniere.exploitable ? EtatCouche.connecte : EtatCouche.recherche;
  }

  /// Source de position choisie dans les parametres (`meta.source_gps`).
  ChoixGps get choixGps => ChoixGps.depuisMeta(base.meta('source_gps'));

  /// Libelle de la source de position, pour l'ecran DT.
  ///
  /// Â« GNSS externe Â» = releve de terrain ; Â« interne Â» = capteur de la
  /// tablette, a ne pas utiliser pour un point de tir ; Â« aucun Â» = service
  /// arrete ou sans mesure.
  String get libelleSourcePosition {
    final PositionTerrain? derniere = servicePosition?.derniere;
    if (derniere == null) return 'aucun';
    return derniere.exploitable ? 'GNSS externe' : 'interne';
  }

  /// Vrai si la derniere position vient d'un recepteur externe.
  bool get positionFiable => servicePosition?.derniere?.exploitable ?? false;

  // ------------------------------------------------------ etats simules (demo)
  // En mode DEMONSTRATION, les quatre badges de la barre du DT suivent des
  // valeurs imposees (4G vert, BLE rouge, Wi-Fi rouge, GPS orange) : le rendu
  // de presentation ne depend plus de la vraie connectivite du poste, souvent
  // absente quand on presente hors du site. Hors demo, chaque getter retombe
  // sur l'etat reel mesure ci-dessus.
  /// Badge 4G de la barre DT : [etat4G].
  EtatCouche get etat4GAffiche => etat4G;
  /// Badge BLE de la barre DT : [etatBle].
  EtatCouche get etatBleAffiche => etatBle;
  /// Badge Wi-Fi (hotspot) de la barre DT : [etatWifiP2p].
  EtatCouche get etatWifiAffiche => etatWifiP2p;
  /// Badge GPS de la barre DT : [etatGps].
  EtatCouche get etatGpsAffiche => etatGps;

  /// Badge 4G : voie montante **reelle** vers le serveur.
  ///
  /// Il combine deux verites distinctes :
  /// - la radio cellulaire est presente ([gsmOnline], alimente par le systeme) ;
  /// - le serveur a repondu au moins une fois ([synchro.serveurRepondu]).
  ///
  /// Le premier critere manquait : sur un spotter associe au point d'acces
  /// local, le systeme declarait Â« en ligne Â» (Wi-Fi present) et le badge
  /// restait vert alors que la 4G etait coupee.
  ///
  /// Rouge si la boucle de synchro n'a pas ete lancee ou si aucune voie de
  /// retour n'existe, orange le temps d'attendre le premier retour, vert
  /// des que le serveur a repondu au moins une fois.
  EtatCouche get etat4G {
    // Sans sonde 4G recente, on ne SAIT pas : orange, jamais vert.
    // Avant, une sonde qui n'aboutissait pas laissait le badge sur son
    // dernier etat â€” vert sur une 4G coupee, ce qui a ete constate a l'ecran.
    if (!_sonde4GRecue) return EtatCouche.recherche;
    // La radio cellulaire absente ou qui vient de tomber : rouge, sans
    // attendre le prochain essai de synchro. `reseauDisponible` seul ne
    // suffisait pas : il ne change qu'au moment ou la boucle l'observe.
    if (!_derniereSondeJoignable) return EtatCouche.arret;
    if (!synchro.actif) return EtatCouche.arret;
    return switch (synchro.serveurRepondu) {
      true => EtatCouche.connecte,
      false => EtatCouche.arret,
      null => EtatCouche.recherche,
    };
  }

  /// Badge BLE : lien etabli avec les excavatrices (TAB 2) ou avec le DT
  /// (TAB 3). Rouge = couche pas demarree, orange = demarree et en
  /// decouverte, vert = au moins un lien authentifie.
  EtatCouche get etatBle {
    if (!bleActif) return EtatCouche.arret;
    return liensBle > 0 ? EtatCouche.connecte : EtatCouche.recherche;
  }

  /// Nombre d'evenements BLE encore non acquittes (file du client), lu
  /// directement sur le client. Sert au bouton d'envoi manuel de l'ecran
  /// Excavator : rien a transmettre quand la file est vide.
  int get fileAttenteBle => _clientBle?.fileAttente.length ?? 0;

  /// Nombre de liens BLE authentifies, lu sur le gateway (TAB 2) ou sur le
  /// client (TAB 3) plutot que sur un compteur que rien ne rafraichit.
  int get liensBle {
    final BleGateway? passerelle = _gatewayBle;
    if (passerelle != null) return passerelle.clientsConnectes.length;
    final BleClient? client = _clientBle;
    if (client != null) return client.connecte ? 1 : 0;
    return 0;
  }

  /// Badge Wi-Fi P2P : meme regle que [etatBle], couche TCP DT <-> spotter.
  EtatCouche get etatWifiP2p {
    if (!wifiActif) return EtatCouche.arret;
    return liensWifi > 0 ? EtatCouche.connecte : EtatCouche.recherche;
  }


  /// Nombre de liens Wi-Fi P2P authentifies (gateway pour le DT, client
  /// pour le spotter).
  int get liensWifi {
    final WifiGateway? passerelle = _gatewayWifi;
    if (passerelle != null) return passerelle.clientsConnectes.length;
    final WifiClient? client = _clientWifi;
    if (client != null) return client.connecte ? 1 : 0;
    return 0;
  }

  /// Repartition des clients Wi-Fi par ROLE, du point de vue d'une passerelle.
  ///
  /// Le Wi-Fi est un bus PARTAGE : l'excavatrice y recoit des DT **et** des
  /// spotters. Afficher « aucun DT » alors qu'un spotter est branche etait
  /// faux ; cette table permet un libelle nominatif (« 1 DT, 2 spotters »).
  ///
  /// Cle = role normalise (`DT`, `SPOT`, `EXCAVATOR`), valeur = nombre de
  /// liens authentifies. Vide cote client (un client n'a qu'un serveur).
  Map<String, int> get wifiParRole {
    final Map<String, int> compte = <String, int>{};
    for (final String role in _rolesWifi.values) {
      final String r = role.trim().toUpperCase();
      if (r.isEmpty) continue;
      compte[r] = (compte[r] ?? 0) + 1;
    }
    return compte;
  }

  /// Roles Wi-Fi authentifies, par « source » (id de l'appareil client).
  final Map<String, String> _rolesWifi = <String, String>{};

  /// Blast, RL et bloc actuellement affiches par l'ecran du spotter.
  ///
  /// La selection vit dans la session et pas dans l'ecran : elle doit survivre
  /// a un changement de profil, et tous les noeuds du reseau suivent le meme
  /// blast. Elle ne sert jamais a interdire la navigation : un blast verrouille
  /// reste consultable et on peut toujours passer a un autre. Vide au
  /// demarrage tant que le serveur n'a pas fourni de blast.
  ///
  /// Selection a 3 niveaux : Blast > RL > Bloc. Changer de blast reset le RL
  /// et le bloc ; changer de RL reset le bloc seulement.
  ///
  /// Les 3 valeurs sont persistees dans `meta` (cles `blast_courant`,
  /// `bloc_courant`, `rl_courant`) pour survivre au redemarrage de l'app.
  String blastCourant = '';
  String rlCourant = '';
  String blocCourant = '';

  /// Blast selectionne, ou null si le numero n'existe plus.
  Blast? get blast => base.parNumero(blastCourant);

  /// Bloc selectionne dans le blast courant, ou null si le bloc n'existe pas
  /// ou si le RL courant ne lui correspond pas (hierarchie Blast > RL > Bloc).
  BlocTravail? get bloc {
    final Blast? b = blast;
    if (b == null) return null;
    final String c = carteCourante;
    return b.bloc(blocCourant, carte: c);
  }

  /// Vrai quand le **bloc courant** est verrouille (paire blast/bloc, v6) :
  /// aucune ligne ne peut plus etre ajoutee dans ce bloc, les autres blocs
  /// du blast ne sont pas concernes.
  bool get verrouille => bloc?.verrouille ?? false;

  /// Mode d'envoi courant (`meta.envoi_mode`) : `blast`, `bloc` ou
  /// `verrouilles` â€” decide du perimetre du bouton Â« Envoyer Â».
  String get envoiMode => base.envoiMode;

  // ---------------------------------------------------------- parametres

  /// Cadence GPS courante, lue dans `meta.intervalle_gps_s` (Â§5).
  late Duration _intervalleGps;

  /// Filtre de distance GPS courant, lu dans `meta.filtre_distance_gps_m`.
  late double _filtreGps;

  Duration get intervalleGps => _intervalleGps;
  double get filtreGps => _filtreGps;

  /// Relit les cles `meta` de l'ecran Parametres et les applique **en direct**
  /// : seuils de detection d'ecart (Â§4) puis, si la cadence ou le filtre GPS
  /// a bouge, redemarrage du service de position (Â§5).
  ///
  /// `api_base`, `api_token` et `envoi_mode` n'ont pas besoin d'etre
  /// recharge : ils sont relus a chaque envoi. Retourne false si un seuil
  /// incoherent est refuse (sortie >= entree) â€” la configuration precedente
  /// est alors conservee et l'ecran l'affiche.
  bool rechargerParametres() {
    final double entree = _doubleMeta('seuil_entree_m', 40);
    final double sortie = _doubleMeta('seuil_sortie_m', 20);
    final Duration delai = _dureeMeta('delai_confirmation_s', 15);
    final bool seuilsOk = detecteurEcart.configurer(
      seuilEntree: entree,
      seuilSortie: sortie,
      delaiConfirmation: delai,
    );

    final Duration intervalle = _dureeMeta('intervalle_gps_s', 5);
    final double filtre = _doubleMeta('filtre_distance_gps_m', 5);
    final bool gpsChange =
        intervalle != _intervalleGps || filtre != _filtreGps;
    _intervalleGps = intervalle;
    _filtreGps = filtre;
    if (gpsChange) _redemarrerGps();

    notifyListeners();
    return seuilsOk;
  }

  /// Redemarre le service GPS avec la cadence et le filtre courants.
  ///
  /// L'abonnement aux mesures est pose avant le demarrage, comme a
  /// l'ouverture de la base : la premiere mesure ne peut pas passer a cote.
  /// Un service jamais cree (base pas encore ouverte) reste inactif.
  void _redemarrerGps() {
    final ServicePosition? ancien = servicePosition;
    if (ancien == null) return;
    ancien.arreter();
    _subMesures?.cancel();
    _subMesures = null;
    servicePosition = ServicePosition(
      base: base,
      intervalle: _intervalleGps,
      filtreDistance: _filtreGps,
    );
    _subMesures = servicePosition!.mesures.listen(traiterMesure);
    servicePosition!.demarrer();
  }

  /// Entier positif lu dans `meta` (secondes), [defaut] si cle absente ou
  /// malformee : une saisie erronee ne casse jamais le demarrage.
  Duration _dureeMeta(String cle, int defaut) {
    final int v = int.tryParse(base.meta(cle) ?? '') ?? defaut;
    return Duration(seconds: v < 1 ? 1 : v);
  }

  /// Nombre decimal lu dans `meta` (metres), [defaut] si cle absente ou
  /// malformee.
  double _doubleMeta(String cle, double defaut) {
    final double v = double.tryParse(base.meta(cle) ?? '') ?? defaut;
    return v < 0 ? defaut : v;
  }

  /// Change de blast et se place sur son premier bloc.
  ///
  /// La carte n'est pas un choix a part : elle appartient au blast, donc
  /// charger le blast charge du meme coup sa carte. Le RL est reinitialise au
  /// premier RL du blast (s'il en a), sinon vide.
  void selectionnerBlast(String numero) {
    final Blast? cible = base.parNumero(numero);
    if (cible == null) return;
    blastCourant = cible.numero;
    // Premier RL = premiere carte (via decoderCarte) ; retombe sur le bloc
    // qui porte cette carte si possible, sinon premier bloc.
    final List<String> rlsDispo = cible.rls;
    if (rlsDispo.isNotEmpty) {
      rlCourant = rlsDispo.first;
      final String? carte = cible.carteDuRl(rlCourant);
      final List<BlocTravail> blocsFiltres = carte == null
          ? cible.blocs
          : cible.blocs
              .where((BlocTravail b) => b.carte == carte)
              .toList(growable: false);
      blocCourant = blocsFiltres.isEmpty
          ? ''
          : blocsFiltres.first.numero;
    } else {
      rlCourant = '';
      blocCourant = cible.blocs.isEmpty ? '' : cible.blocs.first.numero;
    }
    _persisterSelection();
    notifyListeners();
  }

  /// Change de RL a l'interieur du blast courant.
  ///
  /// Le bloc est reinitialise au premier bloc de la carte correspondant au RL
  /// choisi. Si aucun bloc ne correspond, le bloc est vide (cf. choix Q2-B).
  void selectionnerRL(String rl) {
    final Blast? b = blast;
    if (b == null) return;
    if (!b.rls.contains(rl)) return;
    rlCourant = rl;
    final String? carte = b.carteDuRl(rl);
    final List<BlocTravail> blocsFiltres = carte == null
        ? <BlocTravail>[]
        : b.blocs
            .where((BlocTravail b) => b.carte == carte)
            .toList(growable: false);
    blocCourant = blocsFiltres.isEmpty
        ? ''
        : blocsFiltres.first.numero;
    _persisterSelection();
    notifyListeners();
  }

  /// Change de bloc a l'interieur du blast courant.
  ///
  /// Si le bloc choisi n'appartient pas au RL courant, l'appel est refuse :
  /// on garde la coherence de la hierarchie Blast > RL > Bloc.
  void selectionnerBloc(String numero) {
    final Blast? b = blast;
    if (b == null) return;
    // Recherche STRICTE dans le RL courant : le meme numero de bloc existe
    // sur chaque RL (1..n), il ne faut jamais prendre celui d'un autre RL.
    final String carte = carteCourante;
    final BlocTravail? cible =
        b.bloc(numero, carte: carte.isEmpty ? null : carte);
    if (cible == null) return;
    if (blocCourant == numero) return;
    blocCourant = numero;
    _persisterSelection();
    notifyListeners();
  }

  /// Persiste la selection courante (blast + RL + bloc) dans la table `meta`.
  ///
  /// Trois cles distinctes : `blast_courant`, `rl_courant`, `bloc_courant`.
  /// Au demarrage, [restaurerSelection] les relit pour retablir l'etat.
  Future<void> _persisterSelection() async {
    await base.majMeta('blast_courant', blastCourant);
    await base.majMeta('rl_courant', rlCourant);
    await base.majMeta('bloc_courant', blocCourant);
  }

  /// Relit la selection persistee dans `meta` et l'applique, si le blast
  /// existe encore dans la base. Sinon, la selection reste vide (cas normal
  /// si la base a ete purgee entre temps).
  void restaurerSelection() {
    final String blastLu = base.meta('blast_courant') ?? '';
    final String rlLu = base.meta('rl_courant') ?? '';
    final String blocLu = base.meta('bloc_courant') ?? '';
    final Blast? b = base.parNumero(blastLu);
    if (b == null) {
      blastCourant = '';
      rlCourant = '';
      blocCourant = '';
      return;
    }
    blastCourant = blastLu;
    rlCourant = b.rls.contains(rlLu) ? rlLu : '';
    blocCourant = blocLu;
    // Verification finale : si le bloc ne correspond pas au RL, on reset bloc.
    if (rlCourant.isNotEmpty) {
      final BlocTravail? cible = b.bloc(blocCourant);
      final String? rlCible = cible == null
          ? null
          : decoderCarte(cible.carte)?.flitch;
      if (rlCible != rlCourant) blocCourant = '';
    }
  }

  /// Categories de DT de la premiere liste du formulaire.
  List<TypeDT> get typesDT => base.typesDT;

  /// Lot de numeros du type choisi, pour la seconde liste deroulante.
  List<String> idsDuType(String codeType) => base.idsDuType(codeType);

  /// Vrai si ce numero de DT appartient bien a cette categorie.
  bool idAppartientAuType(String codeType, String id) =>
      base.typeDT(codeType)?.contient(id) ?? false;

  /// Carte active selon le RL choisi (ou premiere carte du blast).
  String get carteCourante {
    final Blast? b = blast;
    if (b == null) return '';
    if (rlCourant.isNotEmpty) {
      final String? c = b.carteDuRl(rlCourant);
      if (c != null && c.isNotEmpty) return c;
    }
    return b.carte;
  }

  /// Plan JPG/PNG de la carte courante (selon le RL choisi).
  ///
  /// Priorite stricte carte par carte : le plan local du RL courant s'il est
  /// telecharge, sinon l'URL serveur de CE RL. Le plan du blast n'est qu'un
  /// dernier recours (ancien format a une seule carte).
  String? get planCourant {
    final String c = carteCourante;
    if (c.isNotEmpty) {
      final String? plan = base.planPourCarte(c);
      if (plan != null && plan.isNotEmpty) return plan;
      // AUCUN repli sur `blast.plan` quand une carte precise est demandee :
      // cette colonne ne porte que le plan de la PREMIERE carte du blast.
      // Y retomber afficherait le plan du RL 260 alors que le 262.5 est
      // selectionne. Mieux vaut un etat vide explicite qu'une mauvaise carte.
      return null;
    }
    return blast?.plan;
  }

  /// Point de depart du trajet, lu dans la table des positions.
  ({double lat, double lng})? get positionDepart =>
      base.positionDe(BaseLocale.codeDepart);

  /// Position de la destination courante, si la base la connait.
  ({double lat, double lng})? get positionDestination =>
      base.positionDe(destination);

  /// Derniere mesure GNSS connue (easting/northing UTM + WGS84 source).
  ///
  /// La carte de suivi lit ici la position reelle du device â€” plus aucune
  /// interpolation : tant qu'aucune mesure n'est disponible, la carte ne
  /// dessine pas de camion plutot que d'en dessiner un fictif.
  PositionTerrain? get derniereMesure => servicePosition?.derniere;

  /// Position reelle du DT (WGS84), pour la carte de suivi.
  ({double lat, double lng})? get positionDt {
    final ({double lat, double lng})? wgs = derniereMesure?.wgs84;
    if (wgs != null) return wgs;
    // Repli : conversion UTM -> WGS84 de la derniere mesure (demo offroad,
    // qui ne produit pas de WGS84). Approximation suffisante a l'echelle
    // d'un site (zone UTM unique, deformation << 0,1 % sur quelques km).
    final PositionTerrain? mesure = derniereMesure;
    if (mesure == null) return null;
    return Utm.versWgs84(
      mesure.easting,
      mesure.northing,
      zone: _zoneUtm,
      sud: _sud,
    );
  }

  /// Polyline du parcours recu du serveur, convertie en WGS84 pour la carte
  /// (CDC Â§4 : le champ `parcours` arrive en metres UTM). Le fuseau est le
  /// meme que celui des mesures GNSS â€” deduit une seule fois de la premiere
  /// mesure connue.
  List<({double lat, double lng})>? get parcoursCarte {
    final List<PointParcours>? points =
        CalculateurProgression.parser(base.affectation('parcours'));
    if (points == null || points.length < 2) return null;
    final int zone = _zoneUtm;
    final bool sud = _sud;
    return points
        .map((PointParcours p) => Utm.versWgs84(p.easting.round(),
            p.northing.round(), zone: zone, sud: sud))
        .toList();
  }

  /// Portion deja parcourue de la polyline, pour la ligne verte de la carte :
  /// du depart jusqu'au point projete de la derniere mesure GNSS.
  List<({double lat, double lng})>? get parcoursParcouruCarte {
    final List<({double lat, double lng})>? complet = parcoursCarte;
    final PositionTerrain? mesure = derniereMesure;
    if (complet == null || mesure == null) return null;

    // Projection de la mesure sur chaque segment, comme dans le calculateur :
    // on retrouve le segment courant et le point projete exact.
    final List<PointParcours>? points =
        CalculateurProgression.parser(base.affectation('parcours'));
    if (points == null || points.length < 2) return null;

    double meilleure = double.infinity;
    int indexSegment = 0;
    double tSegment = 0;
    for (int i = 0; i < points.length - 1; i++) {
      final PointParcours a = points[i];
      final PointParcours b = points[i + 1];
      final double dx = b.easting - a.easting;
      final double dy = b.northing - a.northing;
      final double longueur2 = dx * dx + dy * dy;
      double t = 0;
      if (longueur2 > 0) {
        t = ((mesure.easting - a.easting) * dx +
                (mesure.northing - a.northing) * dy) /
            longueur2;
        t = t.clamp(0.0, 1.0).toDouble();
      }
      final double px = a.easting + t * dx;
      final double py = a.northing + t * dy;
      final double d = (mesure.easting - px) * (mesure.easting - px) +
          (mesure.northing - py) * (mesure.northing - py);
      if (d < meilleure) {
        meilleure = d;
        indexSegment = i;
        tSegment = t;
      }
    }

    // Trace tronque : tous les sommets jusqu'au segment courant, puis le
    // point projete exact â€” la ligne verte s'arrete LA, pas au sommet.
    final int zone = _zoneUtm;
    final bool sud = _sud;
    final PointParcours a = points[indexSegment];
    final PointParcours b = points[indexSegment + 1];
    final PointParcours proj = (
      easting: a.easting + tSegment * (b.easting - a.easting),
      northing: a.northing + tSegment * (b.northing - a.northing),
    );
    return <({double lat, double lng})>[
      for (int i = 0; i <= indexSegment; i++)
        Utm.versWgs84(points[i].easting.round(), points[i].northing.round(),
            zone: zone, sud: sud),
      Utm.versWgs84(proj.easting.round(), proj.northing.round(),
          zone: zone, sud: sud),
    ];
  }

  /// Fuseau UTM du site : deduit de la derniere mesure GNSS (celle qui a
  /// servi a la conversion WGS84 -> UTM). Sans mesure, fuseau 31 par defaut
  /// â€” le meme que [Utm.versWgs84].
  int get _zoneUtm {
    final ({double lat, double lng})? wgs = derniereMesure?.wgs84;
    if (wgs != null) return (((wgs.lng + 180) / 6).floor() + 1).clamp(1, 60);
    return 31;
  }

  /// Hemisphere UTM du site : deduit de la derniere mesure GNSS, comme
  /// [Utm.depuisWgs84] le fait pour les mesures. false = nord (defaut),
  /// true = sud. La polyline recue du serveur arrive en metres UTM dans le
  /// meme hemisphere que les mesures : les deux conversions restent donc
  /// coherentes sur un site australien ou sud-americain.
  bool get _sud {
    final ({double lat, double lng})? wgs = derniereMesure?.wgs84;
    if (wgs != null) return wgs.lat < 0;
    return false;
  }

  /// Ajoute une ligne au bloc courant, via la base.
  bool ajouterLigne(LigneBlast ligne) {
    final BlocTravail? cible = bloc;
    if (cible == null) return false;
    final bool ok = base.ajouterLigne(cible, ligne);
    if (!ok) push(base.refusEnCours ?? 'Ajout refuse');
    notifyListeners();
    return ok;
  }

  /// Validation du bloc courant (paire blast/bloc, v6) : la base compte les
  /// lignes de CE bloc, le ferme et journalise l'ecriture. Les autres blocs
  /// du blast restent ouverts tant qu'on ne les verrouille pas.
  void verrouillerBloc() {
    final Blast? blast = this.blast;
    final BlocTravail? cible = bloc;
    if (blast == null || cible == null) return;
    final int lignes = cible.nombreLignes;
    if (!base.verrouiller(cible)) {
      push(base.refusEnCours ?? 'Verrouillage refuse');
      notifyListeners();
      return;
    }
    push(
      'Bloc ${cible.numero} du blast ${blast.numero} verrouille - '
      '$lignes ligne(s) enregistreee(s)',
    );
    notifyListeners();
  }

  /// Reouverture du bloc courant pour reprendre la saisie. Les autres blocs
  /// verrouilles du blast ne sont pas touches.
  void deverrouillerBloc() {
    final Blast? blast = this.blast;
    final BlocTravail? cible = bloc;
    if (blast == null || cible == null) return;
    if (!base.deverrouiller(cible)) {
      push(base.refusEnCours ?? 'Deverrouillage refuse');
      notifyListeners();
      return;
    }
    push(
      'Bloc ${cible.numero} du blast ${blast.numero} deverrouille - '
      'saisie possible',
    );
    notifyListeners();
  }

  /// Transmet au point d'acces Master les donnees deja enregistrees.
  ///
  /// Le perimetre est celui du mode courant ([envoiMode]) : la base refuse si
  /// les conditions du mode ne sont pas remplies ou si le blast est deja
  /// parti : l'ecran n'affiche que le refus, il ne fait jamais l'envoi a la
  /// place.
  bool envoyerDonnees() {
    final Blast? cible = blast;
    if (cible == null) {
      push('Aucun blast selectionne : rien a envoyer');
      notifyListeners();
      return false;
    }
    final bool ok = base.envoyer(cible, numeroBloc: blocCourant);
    if (ok) {
      final String perimetre = switch (envoiMode) {
        BaseLocale.envoiModeBloc => 'Bloc $blocCourant du blast',
        BaseLocale.envoiModeVerrouilles => 'Blocs verrouilles du blast',
        _ => 'Blast',
      };
      push(
        '$perimetre ${cible.numero} envoye - donnees transmises '
        'au point d\'acces Master',
      );
    } else {
      push(base.refusEnCours ?? 'Envoi refuse');
    }
    notifyListeners();
    return ok;
  }

  /// Derniere mesure GNSS du device. Null tant qu'aucun fix n'est acquis :
  /// les tableaux affichent alors Â« â€” Â» au lieu d'inventer des coordonnees.
  ///
  /// Historique : ces champs etaient initialises a des valeurs en dur
  /// (320453/920443/260) â€” l'excavatrice affichait des coordonnees fictives
  /// alors que son GPS n'avait jamais acquis de fix (observe 21/10, badge
  /// GPS Â« search Â», `dumpsys location` : last location=null).
  int? easting;
  int? northing;
  int? elevation;

  int syncCount = 0;

  /// Progression du trajet, calculee localement (CDC Â§4.6) par la
  /// projection de la position GNSS sur la polyline recue du serveur.
  ///
  /// Sans parcours valide (affectation non recue, serveur hors ligne) elle
  /// reste a zero : la barre affiche le depart plutot qu'un avancement
  /// invente.
  double get routeProgress => progression.progression;

  /// Destination courante : choisie **et validee par le serveur**.
  ///
  /// Vide tant que le serveur n'a rien renvoye : la carte reste alors sur son
  /// emplacement d'attente (`positionDestination` -> null -> placeholder)
  /// plutot que sur un point choisi ici. Aucun ecran n'ecrit cette valeur.
  String get destination => base.affectation('destination') ?? '';

  /// Dumping area courante, meme origine que [destination].
  String get dumpingArea => base.affectation('dumping_area') ?? '';

  /// Alerte poussÃ©e par le serveur (option A de la dÃ©tection d'Ã©cart) : le
  /// serveur compare les positions GPS Ã  ses geofences et pose un champ
  /// `alerte` dans `/affectation`. La tablette n'invente rien : elle affiche
  /// le message du serveur, et vide quand rien n'est alertÃ©.
  String get alerteServeur => base.affectation('alerte') ?? '';

  /// Alerte effective de l'ecran DT : l'ecart local (option B) a la priorite,
  /// le repli `alerte` du serveur prend le relais quand aucun parcours n'a
  /// ete recu. Vide = rien a afficher.
  String get alerteCourante {
  if (detecteurEcart.actif && detecteurEcart.horsParcours) {
      final int ecart = (detecteurEcart.derniereDistance ?? 0).round();
      final String cible = dumpingArea.isEmpty ? 'la dumping area' : dumpingArea;
      return 'Hors parcours - ecart $ecart m du trajet vers $cible';
    }
    return alerteServeur;
  }

  /// Vrai tant qu'une alerte est affichable (bandeau + signal sonore).
  bool get alerteActive => alerteCourante.isNotEmpty;

  /// Vrai pendant que l'alerte reste active entre deux mesures : c'est la
  /// memorisation du front montant/descendant de [alerteCourante].
  bool _alerteActive = false;

  /// Une mesure GPS : met a jour la detection d'ecart et signale l'alerte.
  ///
  /// Choix terrain : **chaque mesure pendant l'alerte rejoue le bip et la
  /// vibration** (un chauffeur distrait doit etre repris a chaque position,
  /// pas une seule fois). Sans mesure (GPS off, vehicule immobile sous le
  /// filtre de 5 m), rien ne sonne : le bandeau, lui, reste affiche.
  @visibleForTesting
  void traiterMesure(PositionTerrain mesure) {
    // IDENTITE REQUISE pour persister un evenement (CDC §12 : le serveur
    // refuse un `source_device` vide). Le GPS demarre dans `ouvrirBase()`, donc
    // AVANT le login : sans cette garde, chaque mesure prise sur l'ecran de
    // connexion s'ecrivait avec `source_device = ''` et restait en file pour
    // toujours (25 orphelins mesures sur le DT, 22/10).
    //
    // Le service n'est PAS coupe : la mesure alimente l'affichage (Easting /
    // Northing se remplissent des le demarrage) et le fix satellite reste
    // chaud — seule l'ECRITURE dans la file est sautee.
    if (deviceId.isEmpty) {
      easting = mesure.easting;
      northing = mesure.northing;
      elevation = mesure.elevation;
      notifyListeners();
      return;
    }

    detecteurEcart.parcours(base.affectation('parcours'));
    detecteurEcart.evaluer(
      easting: mesure.easting.toDouble(),
      northing: mesure.northing.toDouble(),
      maintenant: mesure.horodatage ?? DateTime.now(),
    );

    // Progression (CDC Â§4.6) : meme source, meme parser, meme parcours que
    // la detection d'ecart. La barre de trajet et la carte lisent le
    // resultat de ce calcul, la boucle de fond n'invente plus rien.
    progression.parcours(base.affectation('parcours'));
    progression.evaluer(
      easting: mesure.easting.toDouble(),
      northing: mesure.northing.toDouble(),
    );

    // Les tableaux de l'ecran DT suivent la mesure reelle.
    easting = mesure.easting;
    northing = mesure.northing;
    elevation = mesure.elevation;

// Profil excavator (Â§2.3) : pendant qu'un DT est connecte, chaque position
// GNSS de la perle est envoyee en coordonnees de bloc ET accumulee pour la
// moyenne de la session. La projection dans le repere du bloc n'existe pas
// encore (elle viendra avec l'origine du bloc) : on envoie donc la position
// GNSS telle quelle, comme demande ("les coordonnees de chaque position de
// la perle grace au GNSS").
feederPerle(mesure);

// CHAQUE mesure est notifiee : les tableaux et la carte se repeignent a
    // chaud a chaque changement de position (hot reload des valeurs GNSS),
    // meme sans alerte. Le push ci-dessous notifie deja, sauf sur les
    // branches ou l'etat d'alerte n'a pas change â€” on assure donc une
    // notification systematique ici.
    notifyListeners();

    final bool actif = alerteActive;
    if (actif) alerter.jouer();

    if (actif != _alerteActive) {
      _alerteActive = actif;
      if (actif) {
        // Front montant : le journal raconte l'entree en alerte, et la voix
        // off lit le message affiche (le bip, lui, a deja sonne ci-dessus).
        push('Alerte trajet - $alerteCourante');
        unawaited(alerter.dire(alerteCourante));
        return; // push a deja notifie les ecrans.
      }
      // Retour au calme : la voix off confirme le retour sur parcours.
      unawaited(alerter.dire('Retour sur le parcours, bonne route'));
      notifyListeners();
    } else if (actif) {
      // Deja en alerte depuis plusieurs mesures : rafraichit l'ecart affiche.
      notifyListeners();
    }
  }

  // ---------------------------------------------------------- perle (excavator)

  /// Session en cours avec le DT connecte, pour la moyenne des positions de
  /// la perle (profil excavator Â§2.3). Null tant qu'aucun DT n'est connecte.
  SessionPerle? _sessionPerle;

  /// DT de la session en cours (ex. `TAB2-DT13`), lu par l'ecran excavator.
  String dtConnecte = '';

  /// Nombre de positions accumulees dans la session courante.
  int get positionsPerle => _sessionPerle?.nombre ?? 0;

  /// Moyenne courante de la session (recalculee a chaque mesure), pour
  /// l'affichage : null tant que rien n'a ete accumule.
  ///
  /// Â§2.3 : la moyenne n'existe que PENDANT une session avec un DT â€” elle est
  /// gelee et envoyee a la sortie de zone, puis remise a zero. Hors session,
  /// il n'y a rien a moyenner.
  MoyennePerle? get moyennePerle => _sessionPerle?.moyenne;

  /// Ouvre une session perle avec le DT qui vient de se connecter, et
  /// journalise l'evenement a l'ecran ("chaque connexion").
  void ouvrirSessionPerle(String dt) {
    dtConnecte = dt;
    _sessionPerle = SessionPerle(dt: dt);
    // Trace PERSISTANTE : `push()` ne va qu'au ticker et disparait, alors
    // qu'un accumulateur remis a zero a chaque reconnexion BLE expliquait
    // parfaitement un « 0 position(s) » a l'ecran (constat du 27/10).
    base.journaliser('PERLE session ouverte avec $dt');
    push('Perle : session ouverte avec $dt');
    notifyListeners();
  }

  /// Ferme la session perle : gelee + envoi de la moyenne, puis remise a zero.
  ///
  /// Appelee a la sortie de zone du DT ("decollage") ou a la deconnexion.
  /// C'est la moyenne gelee qui part vers le DT (puis le serveur) ; la
  /// session suivante du meme DT repartira de zero.
  void fermerSessionPerle() {
    final SessionPerle? session = _sessionPerle;
    if (session == null) return;
    final MoyennePerle? gelee = session.gelerEtReinitialiser();
    if (gelee != null) {
      base.evenementMoyennePerle(
        xmoy: gelee.xmoy,
        ymoy: gelee.ymoy,
        zmoy: gelee.zmoy,
        nombre: gelee.nombre,
        dt: gelee.dt,
      );
      push('Perle : moyenne envoyee (${gelee.nombre} positions) - ${gelee.dt}');
    }
    base.journaliser(
      'PERLE session fermee avec ${session.dt} (${session.nombre} '
      'position(s) accumulee(s))',
    );
    push('Perle : session fermee avec ${session.dt}');
    _sessionPerle = null;
    dtConnecte = '';
    notifyListeners();
  }

  /// Alimente la session perle d'une mesure GNSS (profil excavator Â§2.3).
  ///
  /// Sans DT connecte, il n'y a rien a envoyer ni a moyenner : la mesure est
  /// ignoree cote perle (elle reste bien sur en file GPS comme toute mesure).
  ///
  /// Envoie la position brute au DT (evenement `POSITION_PERLE`) puis
  /// l'accumule pour la moyenne de la session.
  @visibleForTesting
  void feederPerle(PositionTerrain mesure) {
    final SessionPerle? session = _sessionPerle;
    if (session == null) {
      // Etat incoherent : `dtConnecte` porte un DT alors que l'accumulateur
      // est absent. C'est exactement ce que montre l'ecran (« DT 1500-3 ·
      // 0 position(s) ») et c'est INVISIBLE sans cette trace.
      if (dtConnecte.isNotEmpty) {
        base.journaliser(
          'PERLE ANOMALIE : DT $dtConnecte affiche mais aucune session '
          'ouvert (remise a zero par une reconnexion ?)',
        );
      }
      return;
    }
    // Faute de repere de bloc cote serveur, les coordonnees de bloc sont la
    // position GNSS elle-meme : c'est la position de la perle telle que le
    // GNSS la donne (Â§2.3).
    final int xbloc = mesure.easting;
    final int ybloc = mesure.northing;
    final int zbloc = mesure.elevation;
    base.evenementPositionPerle(
      xbloc: xbloc,
      ybloc: ybloc,
      zbloc: zbloc,
      dt: session.dt,
    );
    session.ajouter(xbloc: xbloc, ybloc: ybloc, zbloc: zbloc);
    // Trace a la premiere mesure de chaque session seulement : journaliser
    // chaque point (toutes les 5 s) noierait le fichier.
    if (session.nombre == 1) {
      base.journaliser('PERLE premiere position de la session ${session.dt}');
    }
  }

  /// Vrai des que le serveur a pose au moins une affectation.
  bool get affectationRecue => base.toutesAffectations.isNotEmpty;

  /// Horodatage de la validation, affiche en badge par l'ecran DT.
  String? get horodatageAffectation =>
      base.horodatageAffectation('destination');

  /// Derniere synchro serveur terminee, a afficher par la supervision (Â§21).
  ///
  /// C'est l'ACK du worker qui la pose : un compteur de boucle de demo ne dit
  /// rien de l'etat du lien avec le serveur.
  DateTime? get derniereSynchro => synchro.derniereSynchro;

  final List<String> notifications = <String>[];

  Timer? _syncTimer;

  void _seedNotifications() {
    // Aucun message invente au demarrage : le ticker ne raconte que ce qui
    // arrive vraiment. Avant la premiere connexion, un seul message neutre.
    notifications.add('En attente de connexion');
  }

  bool connect({required Profil selected, required String id, required String name}) {
    masterConnected = false;
    profile = null;
    deviceId = '';
    deviceName = '';
    syncCount = 1;
    // Le profil est issu du snapshot serveur. Son role et son identifiant
    // doivent former une inscription active ; ne jamais accepter un profil
    // ou un Ã©quipement disparu du rÃ©fÃ©rentiel local.
    final Profil? profilBase = base.profil(selected.code);
    if (profilBase == null ||
        !profilBase.actif ||
        !base.idsDuProfil(profilBase).contains(id) ||
        base.nomDuProfil(profilBase, id) != name) {
      masterConnected = false;
      profile = null;
      deviceId = '';
      deviceName = '';
      push('Connexion refusee : referentiels serveur manquants ou obsoletes');
      notifyListeners();
      return false;
    }
    profile = profilBase;
    deviceId = id;
    deviceName = name;
    // L'identifiant part avec chaque evenement comme source (CDC Â§12).
    base.declarerAppareil(id);
    // Les mesures GPS prises avant ce point portaient un `source_device`
    // vide : elles ne partiront jamais et gonflaient le compteur d'attente.
    // Purge unique, au moment ou l'identite devient enfin connue.
    unawaited(base.purgerEvenementsOrphelins());
    push('Connexion Ã©tablie au point d\'accÃ¨s Master - $name');
    startSyncLoop();
    // L'Ã©tat rÃ©seau (Wi-Fi/4G) devient rÃ©el : on Ã©coute le systÃ¨me au lieu
    // d'un boolÃ©en simulÃ©.
    demarrerSurveillanceReseau();
    // La synchro serveur (Â§14) repart avec la session : les evenements
    // restes en PENDING au precedent demarrage sont deja relus au chargement.
    synchro.demarrer();
    // Le login est valide par les referentiels locaux. Le badge reseau reste
    // pilote par demarrerSurveillanceReseau/etatWifiDevice; il ne doit pas
    // servir de garde d'authentification.
    notifyListeners();
    // Les couches locales ne partent qu'une fois le role connu : c'est ici,
    // et seulement ici, que l'excavatrice ouvre son advertising BLE et son
    // serveur TCP, et que le spotter et le DT deviennent clients. Sans cet
    // appel, les trois tablettes restaient chacun dans leur coin.
    unawaited(demarrerCouchesLocales());
    return true;
  }

  /// Options de connexion choisies dans les Parametres.
  ///
  /// Cle meta `transport_ble` : '1' (defaut) ou '0'. Un mode desactive n'est
  /// ni demarre apres l'authentification, ni affiche dans la supervision —
  /// l'utilisateur ne voit que les transports qu'il a lui-meme coches.
  ///
  /// Cle meta `transport_hotspot` : DESACTIVE par defaut ('1' pour l'activer).
  /// Le hotspot est un TRANSPORT DE REPLI : BLE et XBee sont prioritaires.
  /// Tant que l'un des deux est coche, la couche Wi-Fi ne demarre pas — le
  /// hotspot ne sert qu'a rattraper une session ou ni BLE ni XBee ne sont
  /// disponibles. Un mode desactive n'est ni demarre, ni affiche.
  ///
  /// Cle meta `transport_xbee` : desactive par defaut. Coche, il demarre la
  /// couche radio USB-C et affiche son badge.
  ///
  /// DEFAUT BLE A '0' : le transport BLE n'est plus implicite. Une tablette
  /// fraiche doit n'activer QUE ce que l'operateur coche ; avant, l'absence
  /// de cle valait « BLE actif » et le badge revenait meme apres avoir tout
  /// decoche.
  bool get transportBleActif => base.meta('transport_ble') == '1';

  bool get transportHotspotActif => base.meta('transport_hotspot') == '1';

  bool get transportXbeeActif => base.meta('transport_xbee') == '1';

  /// Vrai si au moins un transport PRIORITAIRE (BLE ou XBee) est coche : le
  /// hotspot de repli ne se lance alors PAS — regle de priorite §6.1.
  bool get transportPrioritaireActif => transportBleActif || transportXbeeActif;

  /// Demarre les couches P2P du role courant (BLE + Wi-Fi + XBee), en
  /// respectant les options de connexion cochees dans les Parametres.
  ///
  /// Sans transport injecte, chaque couche demande ses permissions et prend
  /// son transport reel. En cas d'echec d'une couche, l'autre continue : le
  /// Wi-Fi et le BLE sont deux chemins redondants vers la meme excavatrice,
  /// pas une chaine obligatoire.
  Future<void> demarrerCouchesLocales({
    TransportBle? transportBle,
    TransportWifi? transportWifi,
  }) async {
    if (!_actif) return;
    // Un mode decoche dans les Parametres ne demarre pas : pas de couche,
    // pas de permissions demandees, pas de badge. L'excavatrice decochee
    // « Hotspot » n'ouvre donc ni Wi-Fi Direct ni partage de connexion.
    // PRIORITE §6.1 : BLE et XBee dominent le hotspot. La couche Wi-Fi de
    // repli ne demarre que si elle est cochee ET qu'aucun transport
    // prioritaire ne l'est — sinon elle reste muette (ni badge, ni tentatives).
    final bool bleVoulu = transportBle != null || transportBleActif;
    final bool wifiVoulu = transportWifi != null ||
        (transportHotspotActif && !(bleVoulu || transportXbeeActif));
    // Une case DECOCHEE doit aussi ARRETER ce qui tourne deja : sans ces
    // arrets, enregistrer « XBee seul » laissait le client BLE et le Wi-Fi
    // ouverts (et leurs badges affiches) jusqu'au redemarrage de l'app —
    // c'etait exactement le symptome observe a l'ecran.
    if (!bleVoulu) {
      unawaited(_gatewayBle?.arreter());
      _gatewayBle = null;
      unawaited(_clientBle?.arreter());
      _clientBle = null;
      // Les etats BLE sont des GETTERS (calcules sur `bleActif` et sur les
      // liens reellement ouverts) : il n'y a pas de champ a ecrire. On coupe
      // donc la source, et le badge retombe au rouge tout seul.
      bleActif = false;
    }
    if (!wifiVoulu) {
      unawaited(_gatewayWifi?.arreter());
      _gatewayWifi = null;
      unawaited(_clientWifi?.arreter());
      _clientWifi = null;
      // Meme regle que BLE : les badges Wi-Fi / point d'acces sont calcules
      // sur `wifiActif`. Le mettre a false suffit a les eteindre.
      wifiActif = false;
    }
    if (!transportXbeeActif) {
      unawaited(_xbee?.arreter());
      _xbee = null;
      xbeeActif = false;
    }
    final List<Future<void>> couches = <Future<void>>[];
    if (bleVoulu) {
      couches.add(() async {
        try {
          await demarrerBle(transport: transportBle);
        } catch (e) {
          _direSiActif('BLE indisponible : $e');
        }
      }());
    }
    if (wifiVoulu) {
      couches.add(() async {
        try {
          await demarrerWifi(transport: transportWifi);
        } catch (e) {
          _direSiActif('Wi-Fi indisponible : $e');
        }
      }());
    }
    // XBee : transport radio independant, prioritaire comme le BLE. Il ne
    // demande aucune permission réseau systeme (seulement l'USB host) et ne
    // doit jamais retarder les autres couches.
    if (transportXbeeActif) {
      couches.add(() async {
        try {
          await demarrerXbee();
        } catch (e) {
          _direSiActif('XBee indisponible : $e');
        }
      }());
    }
    if (couches.isEmpty) {
      _direSiActif(
          'Aucun transport coche dans les Parametres (BLE / Hotspot / XBee)');
      return;
    }
    // LES DEUX COUCHES EN PARALLELE : elles etaient lancees en SEQUENCE, et
    // `demarrerBle` attend l'issue du scan/connexion (jusqu'a plusieurs
    // dizaines de secondes, voire jamais si le scan boucle). Le `await` ne
    // rendait donc jamais la main et `demarrerWifi` n'etait JAMAIS execute :
    // le DT recevait sa provision par BLE mais aucun WifiClient n'existait,
    // d'ou le badge « Wi-Fi inactif » alors qu'Android etait connecte
    // (observe le 22/10). Chaque couche est independante : elle echoue ou
    // reussit seule, sans retarder l'autre.
    await Future.wait<void>(couches);
    // Le DT et le spotter rejoignent un point d'acces SANS Internet : sans
    // cette route, Android y envoie tout le trafic et le serveur devient
    // injoignable alors que la 4G fonctionne. L'excavatrice n'est pas
    // concernee : elle n'est pas cliente de son propre reseau.
    // Sans transport Wi-Fi coche, il n'y a pas d'interface P2P a deroguer :
    // on ne touche pas a la route par defaut.
    final Profil? p = profile;
    if (wifiVoulu && p != null && !BaseLocale.estTab3(p.roleCdc)) {
      final bool ok = await WifiDirect.forcerCellulaire();
      _direSiActif(ok
          ? 'Trafic serveur maintenu sur la 4G (point d\'acces local en parallele)'
          : 'Pas de 4G : trafic serveur sur la route par defaut');
    }
    if (_actif) notifyListeners();
  }

  /// Faux des que [dispose] a ete appele.
  ///
  /// Les couches locales demarrent apres [connect] : la tache peut encore
  /// tourner quand l'ecran est detruit (tests, retour arriere). Sans ce
  /// garde-fou, le `push` final touchait un ChangeNotifier detruit.
  bool _actif = true;

  /// [push] sans risque si la session a ete detruite entre-temps.
  void _direSiActif(String message) {
    if (_actif) push(message);
  }

  void disconnect() {
    _syncTimer?.cancel();
    _syncTimer = null;
    _timerRssi?.cancel();
    _timerRssi = null;
    // Les couches de collecte s'eteignent : plus rien ne circule vers le DT.
    unawaited(_gatewayBle?.arreter());
    _gatewayBle = null;
    unawaited(_clientBle?.arreter());
    _clientBle = null;
    unawaited(_gatewayWifi?.arreter());
    _gatewayWifi = null;
    unawaited(_clientWifi?.arreter());
    _clientWifi = null;
    unawaited(_xbee?.arreter());
    _xbee = null;
    xbeeActif = false;
    _relaisTimer?.cancel();
    _relaisTimer = null;
    _timerWifi?.cancel();
    _timerWifi = null;
    _timerHotspot?.cancel();
    _timerHotspot = null;
    // Rend la route par defaut au systeme : les appels suivants ne doivent
    // pas rester attaches a une interface cellulaire qui n'existe plus.
    unawaited(WifiDirect.libererRoute());
    bleActif = false;
    wifiActif = false;
    pointAccesActif = false;
    ssidExcavatrice = '';
    motDePasseExcavatrice = '';
    // Aucune file n'est plus en vol : les fleches d'echange retombent.
    envoiBleActif = false;
    envoiWifiActif = false;
    tab3Connectes = 0;
    clientsWifiConnectes = 0;
    rssiTab3.clear();
    synchro.arreter();
    arreterSurveillanceReseau();
    masterConnected = false;
    push('Deconnexion du reseau local');
    notifyListeners();
  }

  /// Boucle permanente (tache de fond) : filet de securite de l'interface.
  void startSyncLoop() {
    _syncTimer?.cancel();
    _syncTimer = Timer.periodic(const Duration(seconds: 5), (_) => _syncTick());
  }

  // ------------------------------------------------------------------ couche BLE

  /// Gateway BLE de l'excavatrice : c'est l'EXCAVATRICE qui emet (advertising),
  /// les DT s'y accrochent dans un rayon de 10 m. Present seulement pour le
  /// profil excavator (roleCdc = ROLE_TAB3). Sinon null.
  BleGateway? _gatewayBle;

  /// Client BLE du DT : le DT est client, il se connecte a l'excavatrice qui
  /// est dans son rayon. Present seulement pour le profil DT (roleCdc =
  /// ROLE_TAB2). Sinon null.
  BleClient? get clientBle => _clientBle;
  BleClient? _clientBle;

  /// Etat BLE expose aux ecrans (CDC Â§20.2/Â§20.3).
  bool bleActif = false;
  int tab3Connectes = 0;
  final Map<String, int> rssiTab3 = <String, int>{};

  /// Boucle de supervision RSSI du role DT (CDC Â§22). Stockee pour etre
  /// annulee a la deconnexion et a la fermeture : sans cela elle tournait
  /// indefiniment en tache de fond apres la fin de la session.
  Timer? _timerRssi;

  /// Identifiant de la passerelle : c'est l'EXCAVATRICE qui la porte
  /// desormais (inversion des roles). Les DT s'y accrochent dans un rayon
  /// de 10 m.
  static const String idGateway = 'EXC-001';

  /// Identite reseau de cette tablette : l'identifiant enrole, rien d'autre.
  ///
  /// C'est la meme valeur des deux cotes du lien : elle sert de cle
  /// `equipements.id`, de `source_device` dans les evenements, de cle
  /// d'authentification dans `idsAutorises`, et de nom de session perle.
  /// L'unicite des identifiants sur tout le parc (CDC models.dart) garantit
  /// qu'aucune collision de role n'est possible : un `1501` est toujours un
  /// DT, jamais un spotter.
  ///
  /// Le suffixe `deviceName` n'est pas repris : le nom est un libelle
  /// d'affichage, il peut changer sans casser l'authentification.
  String get identiteReseau {
    if (deviceId.isNotEmpty) return deviceId;
    // Aucune session ouverte (tests, ecran de demarrage) : un repli stable
    // et unique evite d'annoncer la meme identite a deux tablettes.
    final Profil? p = profile;
    return p == null ? 'TAB-000' : 'TAB-${p.code.toUpperCase()}-000';
  }

  /// Rayon de connexion du profil excavator, en metres (Â§2.3).
  ///
  /// Un DT n'est accepte ("pret et charge") que s'il est entre dans ce rayon
  /// autour de l'excavatrice ; il en est deconnecte des qu'il en sort
  /// ("decollage"). Vaut 10 m par defaut, reglable dans `meta`
  /// (`rayon_connexion_m`) depuis l'ecran Parametres.
  ///
  /// Note technique : le plugin BLE `ble_peripheral` n'expose aucune API de
  /// puissance d'emission, donc le rayon n'est pas plafonne a l'emission
  /// (option Â« a Â» impossible). Il est applique au **filtrage** (option
  /// Â« b Â») : un DT au-dela du rayon est refuse au handshake, puis
  /// deconnecte par la supervision RSSI.
  double get rayonConnexionM => _doubleMeta('rayon_connexion_m', 10);

  /// Demarre la couche BLE selon le role.
  ///
  /// **Inversion des roles (Voie 1)** : l'**excavatrice** (roleCdc =
  /// ROLE_TAB3) est l'emetteur (peripherique + advertising `ORE-EXC-*`),
  /// les **DT** (roleCdc = ROLE_TAB2) sont les clients qui s'y accrochent
  /// dans un rayon de 10 m.
  ///
  /// Transport injecte par l'appelant : banc pour les tests, transports
  /// reels par defaut â€”
  /// - excavatrice (emetteur) : [TransportBlePeripherique] (ble_peripheral) ;
  /// - DT (client) : [TransportBleCentral] (flutter_reactive_ble).
  Future<void> demarrerBle({TransportBle? transport}) async {
    final Profil? profil = profile;
    if (profil == null) return;
    // Permissions BLE runtime (Android 12+) : sans elles, l'advertising de
    // l'excavatrice et le scan du DT echouent silencieusement. Le manifeste
    // les declare, mais elles ne sont pas accordees pour autant. Aucun effet
    // hors Android, et sans transport injecte (tests) on ne demande rien.
    if (transport == null && !await PermissionsBle.demander()) {
      push('BLE : permissions refusees - couche BLE inactive');
      return;
    }
    final bool estExcavatrice = BaseLocale.estTab3(profil.roleCdc);
    final bool estDt = BaseLocale.estTab2(profil.roleCdc);
    // NOM D'ADVERTISING UNIQUE par excavatrice (27/10).
    //
    // Toutes les tablettes s'annoncaient `ORE-EXC-001` : deux excavatrices
    // dans la meme zone etaient indistinguables pour le scan, et un DT
    // pouvait s'accrocher a la mauvaise — ou ne jamais retrouver la sienne
    // apres une coupure. Le nom derive maintenant de l'identifiant enrole
    // (`EX-2000` -> `ORE-EXC-EX-2000`), le prefixe `ORE-EXC` restant le
    // contrat de decouverte du client.
    // Restauration du transport eprouve (27/10) :
    // - Excavatrice : `TransportBlePeripherique()` sous le nom standard
    //   'ORE-EXC-001' (le nom dynamique cassait l'advertising BLE).
    // - DT / client : `TransportBleCentral()` (flutter_reactive_ble), qui
    //   scanne ouvertement et s'accroche a 'ORE-EXC-001'.
    transport ??= estExcavatrice
        ? TransportBlePeripherique()
        : TransportBleCentral();
    if (estDt) {
      // DT : client BLE, il se connecte a l'excavatrice presente dans son rayon.
      final BleClient client = BleClient(
        transport: transport,
        // Identite reseau = identifiant enrole (`equipements.id`), celui que
        // `idsAutorises` contient cote excavatrice. Un prefixe de role
        // (`TAB2-...`) ferait echouer le handshake en "non enrole" et
        // ouvrirait la session perle sous un nom inconnu du serveur.
        sourceDevice: identiteReseau,
        role: BaseLocale.roleTab2,
        // JOURNAL RESEAU VERS L'UI — cote CLIENT aussi.
        //
        // Sans ce parametre, `BleClient` creait son `JournalBleMemoire`
        // prive : le DT journalisait bel et bien, mais dans un objet que
        // personne ne lisait. La supervision affichait donc « Aucun evenement
        // reseau journalise » alors que la connexion BLE etait etablie et
        // verte (constat du 27/10). Le gateway recevait deja son journal, le
        // client — oublie — non.
        journal: BaseLocale.journalReseau(),
      );
      client.surAck = (String eventId) {
        push('BLE ACK recu - $eventId synchronise');
        // File vidÃ©e par les ACK : la flÃ¨che retombe une fois tout acquittÃ©.
        envoiBleActif = client.fileAttente.isNotEmpty;
        notifyListeners();
      };
      // Boss -> serveur -> DT -> excavatrice -> ici : notification recue par
      // le lien BLE, meme traitement que la descente HTTP et que le Wi-Fi.
      // Sans ce branchement, le canal Boss ne descendait par BLE chez personne.
      client.surNotification = (Map<String, Object?> notif) {
        unawaited(recevoirNotificationLocale(notif));
      };
      // Meme canal de relais que le Wi-Fi : le DT recoit par BLE ce que
      // l'excavatrice lui pousse, le stocke, puis acquitte (ACK du lien).
      client.surEvenement = (Map<String, Object?> evenement) {
        // JOURNAL : c'est l'activite REELLE du DT, et elle etait invisible.
        // Sans cette ligne, la supervision du DT restait figee sur le seul
        // « authentifie par TAB 2 » alors que des evenements arrivaient en
        // continu par le relais (constat du 27/10).
        BaseLocale.journaliserReseau(
          'BLE recu ${evenement['event_type'] ?? '?'} '
          'de ${evenement['source_device'] ?? '?'}',
        );
        _recevoirRelais(evenement, acquitter: (String id) async {
          await client.envoyer(_enveloppeAck(id, client.sourceDevice));
        });
      };
      // Provision recue par BLE : SSID, mot de passe et adresse du serveur.
      // On les memorise (une seule fois dans les Parametres), puis on lance
      // IMMEDIATEMENT la connexion au reseau et au serveur TCP â€” c'est tout
      // le sens du provisionnement : aucune saisie, aucun bouton. Si le
      // reseau est deja memorise par Android, l'association est instantanee.
      client.surProvision = (Map<String, Object?> provision) {
        final String adresse = '${provision['adresse'] ?? ''}';
        if (adresse.isNotEmpty) adressePointAcces = adresse;
        final String ssid = '${provision['ssid'] ?? ''}';
        final String mdp = '${provision['mot_de_passe'] ?? ''}';
        if (ssid.isNotEmpty) {
          ssidExcavatrice = ssid;
          // Memorise pour les redemarrages (comme l'excavatrice le fait).
          unawaited(base.majMeta('reseau_ssid', ssid));
        }
        if (mdp.isNotEmpty) {
          unawaited(base.majMeta('reseau_mot_de_passe', mdp));
        }
        push('BLE : reseau $ssid recu - connexion automatique');
        unawaited(rejoindreReseauExcavatrice());
        notifyListeners();
      };
      _clientBle = client;
      bleActif = true;
      final bool ok = await client.connecter();
      // Session fermee pendant la tentative (deconnexion, destruction de
      // l'ecran) : ne pas relancer de boucle derriere elle.
      if (!_actif) {
        await client.arreter();
        return;
      }
      // APPAIRAGE APPLICATIF — seulement APRES un handshake REUSSI.
      //
      // Memoriser une adresse qui n'a pas abouti ferait viser pour toujours
      // un appareil inutilisable (non enrole, hors service). C'est la regle de
      // la specification : le natif ne memorise rien de lui-meme sur ce chemin.
      if (ok && transport is TransportBleNatif) {
        final TransportBleNatif natif = transport;
        final String adresse = natif.machine.adresse ?? '';
        if (adresse.isNotEmpty) {
          await natif.machine.memoriser(adresse, natif.machine.nom);
        }
      }
      push(ok
          ? 'BLE connectÃ© Ã  l\'excavatrice - authentifiÃ©'
          : 'BLE : excavatrice introuvable - donnÃ©es en file locale');
      // Le DT est pret et charge : il quittera la zone des qu'il decolle
      // (sortie de rayon cote excavatrice, qui le deconnecte).
      if (ok) await _retransmettreFileBle();
      // Reconnexion automatique (REQ-018) : le client BLE retente sans fin,
      // comme le client Wi-Fi. Hors portee, la file reste locale et repart
      // seule au retour de l'excavatrice (demarrage compris : si `connecter`
      // a echoue, la boucle fait la premiere tentative suivante).
      client.demarrerReconnexionAuto();
    } else if (estExcavatrice) {
      // Excavatrice : emet en BLE, accepte les DT entres dans son rayon.
      // En transport reel, demarre l'advertising (le gateway ne le fait pas :
      // c'est le transport qui connait la pile).
      //
      // TRACE INCONDITIONNELLE (27/10). Sans elle, une seule question restait
      // sans reponse : « pourquoi aucune ligne *advertising sous* n'apparait
      // alors que le gateway demarre ? ». Le test de type et l'etat
      // `bleActif` sont desormais ecrits NOIRS SUR BLANC : c'est la premiere
      // chose a lire quand un DT ne trouve pas l'excavatrice.
      base.journaliser(
        'BLE role excavatrice : transport=${transport.runtimeType} '
        'peripherique=${transport is TransportBlePeripherique} '
        'bleActif=$bleActif',
      );
      if (transport is TransportBlePeripherique) {
        final TransportBlePeripherique periph = transport;
        // ANNONCER meme si `bleActif` est deja vrai.
        //
        // `demarrerCouchesLocales()` est appelee a la connexion PUIS a
        // chaque enregistrement des Parametres. Au second passage, `bleActif`
        // valait deja `true` et tout le bloc etait saute — y compris la trace
        // du nom annonce, d'ou des journaux muets alors que le gateway
        // tournait (constat du 27/10). Si la publicite est deja active, on
        // se contente de la REAFFIRMER : c'est idempotent et sans effet de
        // bord, alors qu'un nom perdu rend deux tablettes indistinguables.
        base.journaliser(
          'BLE advertising sous "${periph.nomPublic}"'
          '${bleActif ? ' (deja actif, reaffirme)' : ''}',
        );
        try {
          await periph.demarrerPublicite();
          base.journaliser('BLE advertising demarre');
        } catch (e) {
          // Echec rendu VISIBLE : sans cela, une exception de la pile laissait
          // l'excavatrice muette et invisible des DT, sans aucun indice.
          base.journaliser('BLE advertising ECHEC : $e');
          push('BLE : publicite impossible ($e) - aucun DT ne vous verra');
        }
      } else {
        base.journaliser(
          'BLE advertising NON demarre : transport ${transport.runtimeType} '
          'n\'est pas un peripherique',
        );
      }
      final BleGateway gateway = BleGateway(
        transport: transport,
        idGateway: identiteReseau,
        idsAutorises: base.idsDuRole(BaseLocale.roleTab2).toSet(),
        // Journal reseau VERS L'UI : sans lui, la supervision affichait
        // Â« Aucun evenement reseau journalise Â» alors que la connexion
        // BLE fonctionnait (chaque couche ecrivait dans son journal prive).
        journal: BaseLocale.journalReseau(),
        // Rayon de connexion du profil excavator (Â§2.3) : seuls les DT
        // entres dans ce rayon sont acceptes, et ils sont deconnectes des
        // qu'ils en sortent. Reglable dans `meta` (rayon_connexion_m).
        proximite: ControleurProximite.rayon(rayonM: rayonConnexionM),
      );
      gateway.surEvenement = (String source, Map<String, Object?> evenement) {
        // L'excavatrice recolte, journalise et acquitte.
        base.evenementRecu(evenement);
        push('BLE evenement recu de $source : ${evenement['event_type']}');
        gateway.acquitter(source, '${evenement['event_id']}');
        // Le DT present dans le rayon recoit aussitot ce que le spotter vient
        // de saisir : la boucle periodique couvre le cas du DT absent.
        unawaited(_relayerVersDt());
        notifyListeners();
      };
      // Notifiation recue d'un client : relayee a tous les autres clients
      // authentifies (le serveur central n'est pas joignable du terrain â€”
      // c'est l'excavatrice qui est le relais local du canal Boss).
      gateway.surNotification = (Map<String, Object?> notif) {
        unawaited(recevoirNotificationLocale(notif));
      };
      // Provisionnement : des qu'un DT s'authentifie, il recoit le reseau
      // a rejoindre. C'est ce qui evite toute saisie manuelle cote client.
      gateway.surConnexion = (String source) {
        ouvrirSessionPerle(source);
        unawaited(_provisionnerClient(gateway, source));
      };
      gateway.surProvisionRecue = (String source, Map<String, Object?> m) {
        if (m['ok'] == true) {
          push('Provision confirmee par $source - reseau rejoint');
          notifyListeners();
        }
      };
      gateway.surDeconnexion = (String _) => fermerSessionPerle();
      _gatewayBle = gateway;
      await gateway.demarrer();
      bleActif = true;
      // Boucle de supervision RSSI (CDC Â§22). Un seul timer a la fois :
      // un redemarrage de la couche BLE annule le precedent.
      _timerRssi?.cancel();
      _timerRssi = Timer.periodic(const Duration(seconds: 5), (_) async {
        await gateway.rafraichirRssi();
        tab3Connectes = gateway.clientsConnectes.length;
        rssiTab3
          ..clear()
          ..addAll(gateway.rssiClients);
        notifyListeners();
      });
      push('BLE passerelle active - ${gateway.idsAutorises.length} appareil(s) autorisÃ©(s)');
    }
    notifyListeners();
  }

  /// Etat XBee expose aux ecrans (badge voyant, supervision).
  bool xbeeActif = false;

  /// Badge XBee : allume si le port serie est ouvert, eteint sinon. Aligne sur
  /// les autres voyants pour que le bandeau reste homogene.
  EtatCouche get etatXbee => xbeeActif ? EtatCouche.connecte : EtatCouche.arret;

  /// Alias du bandeau DT (memes voyants sur les trois profils).
  EtatCouche get etatXbeeAffiche => etatXbee;

  /// Transport XBee ouvert, null tant que la couche n'est pas demarree.
  TransportXbee? _xbee;

  /// Demarre la couche XBee (radio 802.15.4 via port USB serie).
  ///
  /// Le DT est un ROVER : il porte un XBee 3 branche en USB-C qui lui livre
  /// ses positions NMEA (GGA). La couche monte la position sur la base et
  /// descend les messages de la base destines a ce DT. Pour l'excavatrice,
  /// la couche ne fait que consigner l'ouverture du port (elle n'a pas de
  /// XBee radio embarque aujourd'hui) — le port, s'il existe, est lu mais
  /// les mesures ne partent nulle part tant qu'il n'y a pas de base.
  Future<void> demarrerXbee() async {
    final Profil? profil = profile;
    if (profil == null) return;
    final TransportXbee xbee = TransportXbee(
      idEmetteur: identiteReseau,
    );
    // Vitesse serie reglable (meta.xbee_baudrate, defaut 115200 = config
    // u-center/XCTU du kit). Le champ vit dans Parametres : un site avec des
    // modules reconfigurees a 9600 ou 230400 n'a pas a rebuilder l'apk.
    final int baud = int.tryParse(base.meta('xbee_baudrate_eff') ??
            base.meta('xbee_baudrate') ?? '') ??
        115200;
    final bool ok = await xbee.demarrer(baudRate: baud);
    if (!_actif) {
      await xbee.arreter();
      return;
    }
    _xbee = xbee;
    xbeeActif = ok;
    if (!ok) {
      push('XBee : aucun module USB detecte - couche inactive');
      notifyListeners();
      return;
    }
    // Positions NMEA du rover : traitees comme des GPS_UPDATE locaux, memes
    // que la couche BLE/Wi-Fi les produit. Chaque mesure part vers la base.
    xbee.positions.listen((MesureGga m) {
      _surPositionXbee(m, xbee);
    });
    // Messages JSON de la base (ou broadcast) : traite comme une descente
    // serveur — notifications d'abord, relais ensuite.
    xbee.messages.listen((String brut) {
      try {
        final Map<String, Object?> j =
            jsonDecode(brut) as Map<String, Object?>;
        final Object? payload = j['payload'];
        if (payload is Map<String, Object?>) {
          if (payload['event_type'] != null) {
            _recevoirRelais(payload, acquitter: (String id) async {
              await xbee.envoyer(<String, Object?>{
                'event_type': 'BLE_RELAY',
                'event_id': id,
                'ack': true,
              });
            });
          }
          if (payload['message'] != null) {
            unawaited(recevoirNotificationLocale(payload));
          }
        }
      } on FormatException {
        // Trame non JSON : ignoree, deja journalisee par le transport.
      }
    });
    push('XBee actif - ${xbee.nomDevice}');
    notifyListeners();
  }

  /// Position GNSS lue sur le port USB du rover.
  ///
  /// Deux effets, dans cet ordre :
  ///  1. **montée** — la mesure est encapsulée en JSON et poussée vers la
  ///     base (`envoyer()`), seule destinataire : aucun autre DT ne la voit ;
  ///  2. **traitement local** — la même mesure alimente l'écran, le parcours
  ///     et la file d'événements via `traiterMesure`, exactement comme une
  ///     mesure du GNSS interne. Sans cela, le DT affichait sa position mais
  ///     rien n'était journalisé : la couche XBee était aveugle côté données.
  ///
  /// Le NMEA donne des degrés WGS84 : on les convertit en UTM (mètres) parce
  /// que c'est l'unité du serveur, du parcours et des positions de la base.
  void _surPositionXbee(MesureGga m, TransportXbee xbee) {
    if (deviceId.isEmpty) return;
    final double? e = _utmEasting(m.latitude, m.longitude);
    final double? n = _utmNorthing(m.latitude, m.longitude);
    if (e == null || n == null) return;

    final Map<String, Object?> mesure = <String, Object?>{
      'event_type': 'GPS_UPDATE',
      'source_device': deviceId,
      'easting': e.round(),
      'northing': n.round(),
      'elevation': m.altitude.round(),
      'qualite': m.qualite,
      'satellites': m.nbSatellites,
      'horodatage': m.horodatage,
    };
    // Montée radio : `dst` = BASE par defaut dans `envoyer`.
    unawaited(xbee.envoyer(mesure));

    traiterMesure(PositionTerrain(
      easting: e.round(),
      northing: n.round(),
      elevation: m.altitude.round(),
      horodatage: DateTime.tryParse(m.horodatage),
      wgs84: (lat: m.latitude, lng: m.longitude),
      source: SourcePosition.externe,
    ));
  }

  /// Conversion WGS84 -> UTM (zone deduite de la longitude, hemisphere nord
  /// par defaut car le site est au nord de l'equateur). Rend null si les
  /// coordonnees sont hors domaine : une mesure aberrante est ignorée plutôt
  /// que d'écrire une position fausse dans la file.
  double? _utmEasting(double lat, double lon) {
    final ({double e, double n})? p = _wgs84VersUtm(lat, lon);
    return p?.e;
  }

  double? _utmNorthing(double lat, double lon) {
    final ({double e, double n})? p = _wgs84VersUtm(lat, lon);
    return p?.n;
  }

  ({double e, double n})? _wgs84VersUtm(double lat, double lon) {
    if (!lat.isFinite || !lon.isFinite) return null;
    if (lat <= -80 || lat >= 84 || lon <= -180 || lon >= 180) return null;
    const double a = 6378137.0;
    const double f = 1 / 298.257223563;
    final double e2 = f * (2 - f);
    final int zone = ((lon + 180) / 6).floor() + 1;
    final double lon0 = ((zone - 1) * 6 - 180 + 3) * 3.141592653589793 / 180;
    final double phi = lat * 3.141592653589793 / 180;
    final double lam = lon * 3.141592653589793 / 180;
    final double k0 = 0.9996;
    final double ep2 = e2 / (1 - e2);
    final double nu = a / math.sqrt(1 - e2 * _sin2(phi));
    final double t = _tan2(phi);
    final double c = ep2 * _cos2(phi);
    final double aa = _cos(phi) * (lam - lon0);
    final double m = a * ((1 - e2 / 4 - 3 * e2 * e2 / 64) * phi -
        (3 * e2 / 8 + 3 * e2 * e2 / 32) * _sin(2 * phi) +
        (15 * e2 * e2 / 256) * _sin(4 * phi));
    final double easting = k0 * nu * (aa +
            (1 - t + c) * aa * aa * aa / 6 +
            (5 - 18 * t + t * t + 72 * c - 58 * ep2) * aa * aa * aa * aa * aa /
                120) +
        500000.0;
    final double northing = k0 * (m + nu * _tan(phi) * (aa * aa / 2 +
            (5 - t + 9 * c + 4 * c * c) * aa * aa * aa * aa / 24 +
            (61 - 58 * t + t * t + 600 * c - 330 * ep2) *
                aa * aa * aa * aa * aa * aa / 720)) +
        (lat < 0 ? 10000000.0 : 0.0);
    return (e: easting, n: northing);
  }

  double _sin(double x) => math.sin(x);
  double _cos(double x) => math.cos(x);
  double _tan(double x) => math.tan(x);
  double _sin2(double x) => math.sin(x) * math.sin(x);
  double _cos2(double x) => math.cos(x) * math.cos(x);
  double _tan2(double x) {
    final double t = math.tan(x);
    return t * t;
  }

  /// Pousse un JSON de position vers la base par la radio XBee, si la
  /// couche est active. Sans couche, ne fait rien (la methode HTTP normale
  /// prend le relais).
  Future<void> envoyerPositionXbee(Map<String, Object?> mesure) async {
    final TransportXbee? x = _xbee;
    if (x == null || !x.pret) return;
    await x.envoyer(mesure);
  }

  @override
  void dispose() {
    _timerRssi?.cancel();
    // Detache le relais de synchro : sans cela, une passe tardive notifiait
    // un ChangeNotifier detruit (meme garde-fou que `_actif`).
    synchro.removeListener(_surSynchro);
    _timerRssi = null;
    _timerWifi?.cancel();
    _timerWifi = null;
    _timerHotspot?.cancel();
    _timerHotspot = null;
    _relaisTimer?.cancel();
    _relaisTimer = null;
    _gatewayBle?.arreter();
    _clientBle?.arreter();
    _gatewayWifi?.arreter();
    _clientWifi?.arreter();
    _xbee?.arreter();
    // Ferme le groupe Wi-Fi Direct : l'excavatrice cesse d'etre point d'acces.
    WifiDirect.arreter();
    servicePosition?.arreter();
    _subMesures?.cancel();
    _subMesures = null;
    // Meme nettoyage pour le maintien : sans cela, l'abonnement survivrait a
    // la fermeture et alimenterait un accumulateur perle detruit.
    _subMaintien?.cancel();
    _subMaintien = null;
    _subConnectivite?.cancel();
    _subConnectivite = null;
    alerter.fermer();
    _syncTimer?.cancel();
    synchro.arreter();
    // Les couches demarrent en arriere-plan : ce drapeau empeche leur fin
    // d'atteindre un notifier detruit.
    _actif = false;
    super.dispose();
  }

  // ------------------------------------------------------------------ couche Wi-Fi

  /// Gateway Wi-Fi de l'excavatrice : c'est l'EXCAVATRICE qui heberge le
  /// serveur TCP, les DT s'y connectent. Present seulement pour le profil
  /// excavator (roleCdc = ROLE_TAB3). Sinon null.
  WifiGateway? _gatewayWifi;

  /// Client Wi-Fi : porte par le spotter (ROLE_TAB1) et desormais aussi par
  /// le DT (ROLE_TAB2) qui se connecte au serveur de l'excavatrice.
  WifiClient? get clientWifi => _clientWifi;
  WifiClient? _clientWifi;

  /// SSID et mot de passe du point d'acces ouvert par l'excavatrice.
  ///
  /// Android les choisit (SSID suffixe pour eviter les collisions), donc ce
  /// sont les seules valeurs valables : les clients doivent s'y connecter
  /// tels quels. Vides pour les autres profils, et tant qu'aucun point
  /// d'acces n'est ouvert.
  String ssidExcavatrice = '';
  String motDePasseExcavatrice = '';

  /// Vrai quand l'excavatrice heberge reellement un point d'acces.
  ///
  /// Ce n'est pas la meme chose que [wifiActif] (la couche TCP tourne) ni que
  /// [etatWifiP2p] (un client est branche) : cet indicateur dit si le
  /// **reseau** existe. Sans lui, un spotter peut tourner en rond sans savoir
  /// qu'aucun point d'acces n'est disponible.
  bool pointAccesActif = false;

  /// Etat du point d'acces, pour le voyant de l'ecran excavator.
  ///
  /// Rouge : couche non demarree, ou demarrage refuse par l'appareil.
  /// Orange : demarrage en cours. Vert : reseau ouvert, SSID disponible.
  EtatCouche get etatPointAcces {
    if (!wifiActif) return EtatCouche.arret;
    if (pointAccesActif) return EtatCouche.connecte;
    return EtatCouche.recherche;
  }

  /// Ã‰tat Wi-Fi exposÃ© aux Ã©crans (mÃªme pattern que [bleActif]).
  bool wifiActif = false;
  int clientsWifiConnectes = 0;

  /// Rafraichit [clientsWifiConnectes] (boucle de 5 s, cote excavatrice).
  Timer? _timerWifi;

  /// Port applicatif ORE TRACKING (les deux cÃ´tÃ©s le connaissent, CDC Â§7).
  static const int portWifi = 45210;

  /// DÃ©marre la couche Wi-Fi selon le rÃ´le.
  ///
  /// **Inversion des roles (Voie 1)** : l'**excavatrice** (ROLE_TAB3) heberge
  /// le serveur TCP ; les **DT** (ROLE_TAB2) et les **spotters** (ROLE_TAB1)
  /// sont clients et s'y connectent. Transport injecte par l'appelant : banc
  /// en memoire pour les tests, [TransportTcpWifi] (sockets reelles) en
  /// fonctionnement normal. Sans transport, la couche reste inactive.
  ///
  /// Le **reseau** lui-meme est cree par [WifiDirect] (Wi-Fi Direct natif) :
  /// l'excavatrice devient Group Owner avant d'ouvrir son serveur TCP. Sur
  /// les plateformes sans Wi-Fi Direct, la couche continue d'ouvrir le serveur
  /// (le reseau doit alors preexister, hotspot manuel).
  Future<void> demarrerWifi({TransportWifi? transport}) async {
    final Profil? profil = profile;
    if (profil == null) {
      // Silence dangereux : sans ce message, une session dont `profile` n'a
      // pas encore ete pose renoncait au Wi-Fi sans laisser de trace — la
      // supervision affichait « Wi-Fi inactif » alors que le systeme etait
      // connecte, et rien n'expliquait pourquoi (observe 22/10).
      _direSiActif('Wi-Fi non demarre : aucun profil de session');
      return;
    }
    final bool estExcavatrice = BaseLocale.estTab3(profil.roleCdc);
    final bool estTab1 = BaseLocale.estTab1(profil.roleCdc);
    final bool estDt = BaseLocale.estTab2(profil.roleCdc);
    if (estExcavatrice) {
      // 1. Le reseau d'abord, et par ordre de preference :
      //
      //    a) **partage de connexion systeme DEJA ACTIF** (active par
      //       l'operateur dans les Reglages). DetectÃ© par l'interface `ap0` :
      //       il est utilise tel quel, avec sa config reelle (SSID/mot de
      //       passe lue depuis Android 12+). C'est la seule voie qui laisse
      //       les clients joindre le serveur TCP.
      //    b) tentative de demarrage par l'app (`TetheringManager`) : ne
      //       marche que si le fabricant autorise l'app (rares, Android 15
      //       refuse sur le parc : TETHER_ERROR_NO_CHANGE_TETHERING_PERMISSION).
      //    c) **plus de repli LocalOnlyHotspot** : depuis Android 13, il
      //       filtre le trafic entrant des clients â€” le reseau crÃ©Ã© serait
      //       visible mais inutilisable pour le TCP (mesure du 20/10 et du
      //       21/10 : ping perdu, nc timeout). L'operateur doit activer le
      //       partage manuellement; l'app ouvre les Reglages sur demande.
      //
      //    Sans reseau, le serveur TCP est quand meme ouvert : il sera joignable
      //    des que le partage apparaitra.
      DemarrageReseau? reseau;
      // 0) WI-FI DIRECT EN PREMIER. Un hotspot systeme (meme active par
      // l'operateur) isole ses clients : sur la Blackview Active 7 / Android 15
      // le dump `SupportedFeatures=111` n'expose PAS CLIENT_ISOLATION, donc
      // les DT associes n'atteignent NI l'hote (10.94.225.38) NI son TCP
      // (ping met, nc « Connection refused » sur tous les ports, mesure du
      // 22/10). Wi-Fi Direct, lui, cree un groupe ou le Group Owner EST
      // joignable par ses clients : c'est la seule voie fonctionnelle.
      // `WifiDirectManager` cree le groupe en Kotlin (createGroup + promotion
      // Group Owner) et expose l'IP du GO a annoncer aux DT par BLE.
      final DemarrageReseau? direct =
          await WifiDirect.demarrerDetaille(nom: 'ORE-EXC-001');
      final bool directOk = direct != null &&
          direct.ok &&
          direct.type == 'wifi_direct';
      if (directOk) {
        reseau = direct;
        push(
          'Wi-Fi Direct actif (groupe ${direct.ssid ?? '-'}) '
          '- adresse ${direct.adresse ?? '-'}',
        );
      } else {
        // Repli historique : partage systeme (isole les clients sur ce parc,
        // mais on garde la voie pour les tablettes ou il fonctionne).
        final PartageActif? dejaActif = await WifiDirect.partageActif();
        if (dejaActif != null) {
        // La config reelle du partage n'est pas lisible (SDK Android 15 : les
        // deux APIs SoftAp sont hors SDK) : on combine avec les Parametres de
        // l'app (`reseau_ssid`/`reseau_mot_de_passe`), que l'operateur saisit
        // une fois pour toutes. La provision BLE n'annonce ces identifiants
        // qu'a un DT authentifie.
        reseau = DemarrageReseau(
          ok: true,
          ssid: base.meta('reseau_ssid') ?? '',
          motDePasse: base.meta('reseau_mot_de_passe') ?? '',
          adresse: dejaActif.adresse,
          type: 'partage-operateur',
        );
        push(
          'Partage de connexion detecte (operateur) - adresse ${dejaActif.adresse}',
        );
        } else {
          final ({bool ok, String? erreur}) partage =
              await WifiDirect.demarrerPartageConnexion();
          if (partage.ok) {
            reseau = const DemarrageReseau(
              ok: true,
              ssid: PartageConnexionSsid.ssid,
              motDePasse: PartageConnexionSsid.motDePasse,
              type: 'partage',
            );
            push(
              'Partage de connexion systeme actif - SSID ${PartageConnexionSsid.ssid}',
            );
          } else {
            // Pas de hotspot auto-ouvert : on reste propre et on attend
            // l'activation manuelle (bouton Â« Ouvrir les rÃ©glages Â»).
            push(
              'Partage systeme non disponible (${partage.erreur ?? 'inconnu'}) '
              '- activez le point d\'accÃ¨s dans les rÃ©glages Android',
            );
          }
        }
      }
      ssidExcavatrice = reseau?.ssid ?? '';
      motDePasseExcavatrice = reseau?.motDePasse ?? '';
      pointAccesActif = reseau?.ok == true;
      // Adresse du point d'acces : lue sur l'interface du partage, pas
      // devinee. Si elle n'est pas encore la, elle le sera aprÃ¨s activation
      // manuelle; la surveillance (timerHotspot) la relÃ©vera.
      adressePointAcces = reseau?.adresse ?? '';
      if (reseau?.ok == true) {
        push(
          reseau!.type == 'hotspot'
              ? 'Point d\'acces actif - SSID ${reseau.ssid ?? idGateway} '
                  '(mot de passe ${reseau.motDePasse ?? '-'})'
              : 'Wi-Fi Direct : groupe $idGateway cree (point d\'acces actif)',
        );
      } else {
        push(
          'Point d\'acces indisponible : ${reseau?.erreur ?? 'aucune reponse'} '
          '- donnees en file locale',
        );
      }
      // 2. Puis le serveur applicatif, sur l'interface du groupe.
      final TransportTcpWifi tcp = transport is TransportTcpWifi
          ? transport
          : TransportTcpWifi(port: portWifi);
      await tcp.heberger();
      transport = tcp;
    }
    if (transport == null) return;
    if (estTab1 || estDt) {
      // Spotter (TAB 1) ou DT (TAB 2) : client Wi-Fi vers le serveur de
      // l'excavatrice.
      //
      // D'abord le reseau : on decouvre le groupe Wi-Fi Direct de l'excavatrice
      // et on s'y connecte. Sans cela, il n'existe aucune interface pour
      // joindre son serveur TCP (plus de hotspot manuel a configurer).
      // Le reseau n'est plus cherche par Wi-Fi Direct (qui echoue sur
      // Android 15) : c'est le BLE qui annonce SSID + mot de passe, apres
      // authentification. Sans provision recue, la file reste locale.
      final WifiClient client = WifiClient(
        transport: transport,
        // Meme regle que le BLE : le `source_device` doit etre l'identifiant
        // enrole, pas un prefixe de role (voir `identiteReseau`).
        sourceDevice: identiteReseau,
        role: estTab1 ? BaseLocale.roleTab1 : BaseLocale.roleTab2,
        // Meme oubli que cote BLE : sans journal injecte, le client Wi-Fi
        // ecrivait dans son `JournalWifiMemoire` prive et la supervision
        // restait muette alors que des evenements passaient.
        journal: BaseLocale.journalReseau(),
      );
      client.surAck = (String eventId) {
        push('Wi-Fi ACK reÃ§u - $eventId transmis');
        // File vidÃ©e par les ACK : la flÃ¨che retombe une fois tout acquittÃ©.
        envoiWifiActif = client.fileAttente.isNotEmpty;
        notifyListeners();
      };
      // Boss -> serveur -> DT (excavatrice) -> ici : notification recue sur
      // le lien local. Meme traitement que la descente HTTP (stockage en
      // base + bandeau), le curseur est le meme donc aucun double affichage.
      client.surNotification = (Map<String, Object?> notif) {
        unawaited(recevoirNotificationLocale(notif));
      };
      // Meme canal de relais que le BLE : le DT recoit par TCP ce que
      // l'excavatrice lui pousse.
      client.surEvenement = (Map<String, Object?> evenement) {
        // Meme trace que cote BLE : l'activite reelle du canal doit etre
        // lisible dans la supervision, sinon elle parait inerte.
        BaseLocale.journaliserReseau(
          'Wi-Fi recu ${evenement['event_type'] ?? '?'} '
          'de ${evenement['source_device'] ?? '?'}',
        );
        _recevoirRelais(evenement, acquitter: (String id) async {
          await client.envoyer(_enveloppeAck(id, client.sourceDevice));
        });
      };

      // Reconnexion automatique (REQ-008) : Ã  chaque retour de lien, la file
      // repart automatiquement (l'envoi initial est dans _retransmettreFileWifi).
      client.surReconnexion = _retransmettreFileWifi;
      _clientWifi = client;
      wifiActif = true;
      // Sequence stricte (21/10) : 1) rejoindre le reseau (association +
      // detection de l'adresse serveur) ; 2) connecter le client TCP. En
      // parallele, les deux echouaient : `rejoindreReseau` et `connecter`
      // se battaient pour le meme client, et le sondage d'adresse tournait
      // avant que le Wi-Fi ne soit associe (pas d'IP locale encore).
      //
      // Sans BLE, les cles des Parametres suffisent (la provision BLE n'est
      // qu'un raccourci pour les poser). Si le reseau est deja memorise par
      // Android, l'association est immediate.
      final String ssidLocal = base.meta('reseau_ssid') ?? '';
      if (ssidLocal.isNotEmpty) {
        await rejoindreReseauExcavatrice();
      }
      final bool ok = await client.connecter(
        // Adresse du serveur de l'excavatrice : lue dans `meta`
        // (`adresse_point_acces`, posee par la provision BLE) ou detectee
        // sur l'interface. Sans elle, le client chercherait un SSID
        // `ORE-EXC` qui n'existe pas (le partage s'appelle AndroidShare_xxx).
        adresseImposee: adressePointAcces,
      );
      push(ok
          ? 'Wi-Fi connectÃ© Ã  l\'excavatrice - authentifiÃ©'
          : 'Wi-Fi : excavatrice introuvable - donnÃ©es en file locale');
      // Reconnexion automatique (REQ-008) : hors portÃ©e, le client retente.
      await client.demarrerReconnexionAuto();
      // DÃ¨s que le Wi-Fi devient vert, la file part automatiquement (CDC Â§16.1) :
      // la flÃ¨che d'Ã©change s'anime pendant l'envoi et l'attente des ACK.
      _retransmettreFileWifi();
    } else if (estExcavatrice) {
      // Excavatrice : heberge le serveur, collecte les donnees des DT et des
      // spotters qui s'y connectent.
      final WifiGateway gateway = WifiGateway(
        transport: transport,
        idGateway: idGateway,
        idsAutorises: <String>{
          ...base.idsDuRole(BaseLocale.roleTab1),
          ...base.idsDuRole(BaseLocale.roleTab2),
        },
        // Journal reseau vers l'UI, comme pour le BLE.
        journal: BaseLocale.journalReseau(),
      );
      gateway.surEvenement = (String source, Map<String, Object?> evenement) {
        // MÃªme traitement que le BLE : rÃ©colte, journalise, acquitte.
        base.evenementRecu(evenement);
        push('Wi-Fi donnÃ©es reÃ§ues de $source : ${evenement['event_type']}');
        gateway.acquitter(source, '${evenement['event_id']}');
        unawaited(_relayerVersDt());
        notifyListeners();
      };
      // Notification recue d'un client Wi-Fi (Boss -> serveur -> DT ->
      // excavatrice -> spotter) : stockee et re-diffusee aux autres clients.
      gateway.surNotification = (Map<String, Object?> notif) {
        unawaited(recevoirNotificationLocale(notif));
      };
      // Presence detectee par le point d'acces : meme traitement que le BLE.
      // Seul un DT ouvre une session perle ; un spotter est seulement
      // journalise (il ne porte pas de moyenne de position).
      gateway.surConnexion = (String source, String role) {
        // Memorise le ROLE de chaque client : le Wi-Fi est un bus partage
        // (DT + spotters), la supervision doit pouvoir les nommer.
        _rolesWifi[source] = role;
        clientsWifiConnectes = gateway.clientsConnectes.length;
        if (BaseLocale.estTab2(role)) {
          ouvrirSessionPerle(source);
        } else {
          push('$source connecte au point d\'acces');
        }
        notifyListeners();
      };
      gateway.surDeconnexion = (String source) {
        _rolesWifi.remove(source);
        clientsWifiConnectes = gateway.clientsConnectes.length;
        // Fin de la session perle seulement si c'est le DT qui partait.
        if (_sessionPerle != null && dtConnecte == source) {
          fermerSessionPerle();
        } else {
          push('$source deconnecte du point d\'acces');
        }
        notifyListeners();
      };
      _gatewayWifi = gateway;
      await gateway.demarrer();
      wifiActif = true;
      // Surveillance agressive du point d'acces (toutes les 5 s).
      //
      // Android peut fermer le hotspot sans prevenir (bascule Wi-Fi,
      // economie d'energie) : l'application continuait alors d'afficher un
      // SSID que personne ne pouvait voir, et les clients ne trouvaient
      // rien. On verifie que l'interface emet vraiment, et on relance.
      _demarrerSurveillanceHotspot();
      // Compteurs du point d'acces : sans cette boucle, le nombre de clients
      // Wi-Fi restait a zero et le badge ne reflechissait jamais la realite.
      _timerWifi?.cancel();
      _timerWifi = Timer.periodic(const Duration(seconds: 5), (_) {
        clientsWifiConnectes = gateway.clientsConnectes.length;
        notifyListeners();
      });
      _demarrerRelaisVersDt();
      push('Wi-Fi point d\'accÃ¨s actif - ${gateway.idsAutorises.length} appareil(s) autorisÃ©(s)');
    }
    notifyListeners();
  }

  /// Surveille le point d'acces et le relance des qu'il cesse d'emettre.
  ///
  /// Cadence courte (5 s) assume : sans reseau, rien d'autre ne fonctionne
  /// sur les trois tablettes. Une verification coute une lecture
  /// d'interface, pas une requete reseau.
  void _demarrerSurveillanceHotspot() {
    _timerHotspot?.cancel();
    _timerHotspot = Timer.periodic(const Duration(seconds: 5), (_) async {
      // Priorite au partage systeme (refonte 21/10) : `adressePointAcces()`
      // historique lit le groupe Wi-Fi Direct (`adresseGroupOwner`), qui
      // n'existe plus â€” le reseau vient desormais du partage active par
      // l'operateur (interface `ap0`). Le badge restait orange alors que le
      // reseau emettait reellement.
      final PartageActif? partage = await WifiDirect.partageActif();
      bool actif = partage != null;
      String? adresse = partage?.adresse;
      if (!actif) {
        // Repli : hotspot local (si le fabricant autorise l'app a en ouvrir).
        final bool emet = await WifiDirect.verifierHotspot();
        adresse = emet ? await WifiDirect.adressePointAcces() : null;
        actif = emet && adresse != null;
      }
      if (actif != pointAccesActif) {
        pointAccesActif = actif;
        push(actif
            ? 'Point d\'acces retabli ($adresse)'
            : 'Point d\'acces interrompu - activez le partage dans les reglages');
        notifyListeners();
      }
      if (actif) adressePointAcces = adresse!;
    });
  }

  /// Minuterie de surveillance du point d'acces.
  Timer? _timerHotspot;

  /// Traite un evenement recu par relais (excavatrice -> cette tablette).
  ///
  /// On le stocke dans la file locale (`PENDING`), puis on acquitte : c'est
  /// cet ACK qui autorise le relais a le retirer de sa propre file. Stocker
  /// avant d'acquitter garantit qu'une coupure entre les deux ne perd rien.
  void _recevoirRelais(
    Map<String, Object?> evenement, {
    required Future<void> Function(String eventId) acquitter,
  }) {
    final Map<String, Object?>? normalise = base.evenementRecu(evenement);
    if (normalise == null) return;
    push(
      'Donnees recues de ${normalise['source_device']} : '
      '${normalise['event_type']}',
    );
    notifyListeners();
    unawaited(acquitter('${normalise['event_id']}'));
  }

  /// Envoie la provision reseau (SSID + mot de passe) a un client BLE.
  ///
  /// Le message ne part qu'apres le handshake : un appareil non enrole ne
  /// peut donc jamais recevoir les identifiants du point d'acces.
  Future<void> _provisionnerClient(BleGateway gateway, String source) async {
    if (ssidExcavatrice.isEmpty) return;
    final int servis = await gateway.provisionner(
      BleProtocole.provision(
        ssid: ssidExcavatrice,
        motDePasse: motDePasseExcavatrice,
        adresse: adressePointAcces,
        port: portWifi,
      ),
    );
    if (servis > 0) push('Provision reseau envoyee a $servis client(s)');
  }

  /// Adresse IPv4 du point d'acces (celle que les clients joignent en TCP).
  String adressePointAcces = '';

  /// Sonde les candidates pour trouver le serveur de l'excavatrice (port
  /// [port]) : Android 15 place l'hote du partage a une IP arbitraire
  /// (observee .38, pas la convention .1) â€” on teste les deux, la premiere
  /// qui accepte TCP gagne. Rend vide si aucune ne repond.
  Future<String> _sonderServeur(String locale) async {
    final RegExp ip = RegExp(r'^(\d+\.\d+\.\d+)\.\d+$');
    final RegExpMatch? m = ip.firstMatch(locale);
    if (m == null) return '';
    final String base = m.group(1)!;
    for (final String dernier in const <String>['.1', '.38']) {
      final String cible = '$base$dernier';
      try {
        final Socket s =
            await Socket.connect(cible, portWifi, timeout: const Duration(seconds: 2));
        s.destroy();
        return cible;
      } catch (_) {
        // Pas de serveur sur cette IP : candidate suivante.
      }
    }
    return '';
  }

  /// Rejoint le reseau annonce par l'excavatrice (provision recue par BLE).
  ///
  /// Le transport Wi-Fi du client est deja en place : on lui donne seulement
  /// l'adresse a joindre, puisqu'Android a choisi un SSID aleatoire que l'on
  /// ne peut pas reconnaitre a son nom.
  /// Rejoint le point d'acces de l'excavatrice avec les identifiants saisis
  /// dans les parametres (`reseau_ssid`, `reseau_mot_de_passe`).
  ///
  /// Appelee par l'operateur (bouton) ou au demarrage quand les deux cles
  /// existent. C'est la voie qui reste quand le BLE du modele n'emet pas :
  /// une saisie **unique**, puis Android memorise le reseau.
  Future<bool> rejoindreReseauExcavatrice() async {
    // WI-FI DIRECT D'ABORD : c'est la seule voie ou l'hote est joignable
    // depuis ses clients (le hotspot systeme isole, mesure du 22/10).
    // Le groupe porte le prefixe `ORE-EXC` ; on le decouvre puis on s'y
    // connecte. En cas d'echec, on retombe sur le SSID memorise.
    try {
      final List<Map<String, String>> pairs = await WifiDirect.decouvrir();
      final Map<String, String> groupe = pairs.firstWhere(
        (Map<String, String> p) =>
            // ANDROID 10+ IMPOSE `DIRECT-` + 2 caracteres pour le nom du
            // groupe (voir `nomGroupeDirect` cote Kotlin, qui renvoie
            // `DIRECT-OR`). Chercher `ORE-EXC` ne trouvait donc JAMAIS rien :
            // l'excavatrice creait un groupe que le DT ne reconnaissait pas.
            // On accepte les deux formes — prefixe applicatif historique et
            // prefixe impose par le framework.
            (p['nom'] ?? '').toUpperCase().startsWith('ORE-EXC') ||
            (p['nom'] ?? '').toUpperCase().startsWith('DIRECT-'),
        orElse: () => const <String, String>{},
      );
      if (groupe.isNotEmpty) {
        final String nom = groupe['nom'] ?? 'ORE-EXC-001';
        push('Wi-Fi Direct : groupe $nom trouve - connexion...');
        final bool okDirect = await WifiDirect.connecter(nom: nom);
        if (okDirect) {
          // L'IP du Group Owner est toujours 192.168.49.1 en Wi-Fi Direct.
          adressePointAcces = groupe['adresse'] ?? '192.168.49.1';
          push('Wi-Fi Direct : groupe rejoint - serveur $adressePointAcces');
          await _retransmettreFileWifi();
          notifyListeners();
          return true;
        }
        push('Wi-Fi Direct : connexion refusee par le groupe $nom');
      } else {
        push('Wi-Fi Direct : aucun groupe ORE-EXC a portee');
      }
    } catch (e) {
      push('Wi-Fi Direct indisponible : $e');
    }

    final String ssid = base.meta('reseau_ssid') ?? '';
    final String mdp = base.meta('reseau_mot_de_passe') ?? '';
    if (ssid.isEmpty) {
      push('Aucun reseau enregistre : renseignez SSID et mot de passe dans '
          'les parametres');
      notifyListeners();
      return false;
    }
    // Si l'adresse serveur est inconnue, on la cherche D'ABORD par sondage :
    // le device est souvent DEJA associe au partage (Android le memorise) â€”
    // dans ce cas `rejoindreReseau` natif rend false (deja connecte) et on
    // ne doit pas s'arreter la, sinon le client TCP n'aurait jamais de cible.
    final String locale = await WifiDirect.adresseLocale() ?? '';
    if (adressePointAcces.isEmpty && locale.isNotEmpty) {
      adressePointAcces = await _sonderServeur(locale);
    }
    final bool ok = await WifiDirect.rejoindreReseau(ssid, mdp);
    if (ok) {
      if (adressePointAcces.isEmpty) {
        adressePointAcces = await WifiDirect.adressePointAcces() ?? '';
      }
      // Re-lit l'IP locale APRES l'association : avant, le Wi-Fi n'avait pas
      // encore d'adresse et le sondage ne pouvait rien trouver.
      final String localeApres = await WifiDirect.adresseLocale() ?? '';
      if (adressePointAcces.isEmpty && localeApres.isNotEmpty) {
        adressePointAcces = await _sonderServeur(localeApres);
      }
      await _retransmettreFileWifi();
      await _retransmettreFileBle();
      push('Reseau de l\'excavatrice rejoint ($ssid) - serveur $adressePointAcces');
    } else if (adressePointAcces.isNotEmpty) {
      // Association deja en place (Android memorise) : le ressaillage natif
      // a rendu false mais le reseau est LA et l'adresse serveur est trouvee
      // par sondage. On continue comme une reussite.
      push('Reseau deja associe ($ssid) - serveur $adressePointAcces');
    } else {
      push('Reseau $ssid injoignable : verifiez le SSID et le mot de passe');
    }
    // Le client TCP a peut-etre demarre SANS adresse (provision pas encore
    // recue) : maintenant qu'elle est la, on relance sa connexion. La
    // reconnexion automatique du client (REQ-008) reprendra de toute facon,
    // mais elle peut attendre son prochain cycle â€” ici on force immediat.
    final WifiClient? clientWifi = _clientWifi;
    if (clientWifi != null && !clientWifi.connecte) {
      final bool relance = await clientWifi.connecter(
        adresseImposee: adressePointAcces,
      );
      push(relance
          ? 'Wi-Fi connecte a l\'excavatrice - authentifie'
          : 'Wi-Fi : serveur toujours injoignable - nouvelle tentative plus tard');
    }
    notifyListeners();
    return ok;
  }

  /// Enveloppe d'acquittement pour un evenement recu par relais.
  Map<String, Object?> _enveloppeAck(String eventId, String _) =>
      <String, Object?>{
        'type': 'ACK',
        'event_id': eventId,
      };

  // ----------------------------------------------------- relais excavatrice -> DT

  /// Boucle de vidage de la file locale vers le DT.
  ///
  /// L'excavatrice collecte les saisies du spotter et les positionnements du
  /// DT, mais c'est le DT qui a la 4G : c'est donc lui qui doit porter les
  /// evenements jusqu'au serveur. Tant qu'il est absent, la file reste en
  /// `PENDING` et rien n'est perdu (REQ-012) : la boucle reprend des son
  /// retour, sans intervention.
  Timer? _relaisTimer;

  /// Cadence de la boucle : assez courte pour que le DT parte avec les
  /// donnees fraiches, assez longue pour ne pas saturer le lien radio.
  static const Duration cadenceRelais = Duration(seconds: 10);

  /// Vrai pendant qu'une passe de relais est en vol : sans ce verrou, le
  /// timer et le relais immediat pourraient envoyer deux fois le meme lot.
  bool _relaisEnCours = false;

  void _demarrerRelaisVersDt() {
    _relaisTimer?.cancel();
    _relaisTimer = Timer.periodic(cadenceRelais, (_) => _relayerVersDt());
    unawaited(_relayerVersDt());
  }

  /// Pousse la file `PENDING` vers le ou les DT connectes.
  ///
  /// Un evenement n'est retire de la file que lorsque le DT l'a **acquitte**
  /// (retrait dans `surAck`), jamais au simple depart sur le fil : une
  /// coupure en cours de route le laisse donc en attente.
  Future<void> _relayerVersDt() async {
    if (_relaisEnCours) return;
    final BleGateway? gatewayBle = _gatewayBle;
    final WifiGateway? gatewayWifi = _gatewayWifi;
    final bool dtBle = gatewayBle != null && gatewayBle.clientsConnectes.isNotEmpty;
    final bool dtWifi = gatewayWifi != null && gatewayWifi.clientsConnectes.isNotEmpty;
    if (!dtBle && !dtWifi) return;

    _relaisEnCours = true;
    try {
      final List<Map<String, Object?>> file = await base.evenementsPourRelais();
      if (file.isEmpty) return;
      int partis = 0;
      if (dtWifi) {
        // Wi-Fi d'abord : le TCP accepte les lots et acquitte par lien.
        for (final Map<String, Object?> evenement in file) {
          if (evenement['event_id'] == null) continue;
          await gatewayWifi.diffuserEvenement(evenement);
          // Marque relayÃ© immÃ©diatement : l'ACK du DT confirme la rÃ©ception,
          // et le filtre de `evenementsPourRelais` garantit qu'une ligne
          // transmise ne repart jamais (sinon boucle infinie, 21/10).
          await base.marquerRelaye('${evenement['event_id']}');
          partis++;
        }
      } else if (dtBle) {
        for (final Map<String, Object?> evenement in file) {
          if (evenement['event_id'] == null) continue;
          await gatewayBle.diffuserEvenement(evenement);
          await base.marquerRelaye('${evenement['event_id']}');
          partis++;
        }
      }
      if (partis > 0) {
        push('Relais vers le DT - $partis evenement(s) transmis');
        notifyListeners();
      }
    } catch (e) {
      // Lien coupe pendant le lot : la file reste intacte, la boucle reprendra.
      push('Relais vers le DT interrompu : $e');
    } finally {
      _relaisEnCours = false;
    }
  }

  /// Vrai pendant une transmission effective vers le DT (REQ-007) : la
  /// flÃ¨che d'Ã©change ([DataExchangeButton]) s'anime tant que la file Wi-Fi
  /// contient des Ã©vÃ©nements non acquittÃ©s.
  bool envoiWifiActif = false;

  /// Idem [envoiWifiActif] pour le lien BLE (TAB 3 -> TAB 2, CDC Â§7) : la
  /// flÃ¨che s'anime tant que la file BLE contient des non-acquittÃ©s.
  bool envoiBleActif = false;

  /// Transmet toute la file PENDING de la base au DT via le client BLE.
  /// AppelÃ© dÃ¨s que le lien BLE devient vert (authentification Â§9).
  Future<void> _retransmettreFileBle() async {
    final BleClient? client = _clientBle;
    if (client == null || !client.connecte) return;
    if (!base.estPersistee) return;
    envoiBleActif = true;
    notifyListeners();
    try {
      final List<Map<String, Object?>> file = await base.evenementsEnAttente();
      for (final Map<String, Object?> evenement in file) {
        await client.envoyer(evenement);
      }
    } finally {
      envoiBleActif = client.fileAttente.isNotEmpty;
      notifyListeners();
    }
  }

  /// Relance manuelle de la file BLE vers le DT (bouton d'envoi manuel de
  /// l'ecran Excavator).
  ///
  /// L'envoi est deja automatique des que le lien est authentifie (Â§16.1) :
  /// ce bouton ne sert qu'a forcer une reprise quand une transmission a
  /// echoue en cours de route (radio coupee, ACK perdu). Contrairement a
  /// [_retransmettreFileBle] qui sort en silence si le lien est absent, on
  /// journalise ici pour que l'appui sur le bouton ne soit jamais muet.
  Future<void> forcerEnvoiBle() async {
    final BleClient? client = _clientBle;
    if (client == null || !client.connecte) {
      push('Envoi manuel BLE : aucun lien avec le DT - donnees conservees en file');
      notifyListeners();
      return;
    }
    if (!base.estPersistee) {
      push('Envoi manuel BLE : base non persistee - envoi impossible');
      notifyListeners();
      return;
    }
    await _retransmettreFileBle();
    push('Envoi manuel BLE : file relancee vers le DT');
    notifyListeners();
  }

  /// Transmet toute la file PENDING de la base au DT via le client Wi-Fi.
  ///
  /// AppelÃ© dÃ¨s que le lien Wi-Fi devient vert (connexion/authentification,
  /// y compris aprÃ¨s une reconnexion automatique REQ-008). La flÃ¨che reste
  /// animÃ©e tant que des Ã©vÃ©nements ne sont pas acquittÃ©s (CDC Â§16.1).
  Future<void> _retransmettreFileWifi() async {
    final WifiClient? client = _clientWifi;
    if (client == null || !client.connecte) return;
    if (!base.estPersistee) return;
    envoiWifiActif = true;
    notifyListeners();
    try {
      final List<Map<String, Object?>> file = await base.evenementsEnAttente();
      for (final Map<String, Object?> evenement in file) {
        await client.envoyer(evenement);
      }
    } finally {
      envoiWifiActif = client.fileAttente.isNotEmpty;
      notifyListeners();
    }
  }

  /// Filet de securite de l'interface (tache de fond).
  ///
  /// La boucle ne simule plus rien : les positions viennent du GPS reel
  /// ([ServicePosition]), la synchro serveur du worker ([Synchronisation]) qui
  /// pousse ses propres messages, et la progression du trajet est calculee
  /// localement par projection GNSS sur la polyline recue
  /// ([CalculateurProgression], CDC Â§4.6) â€” voir [traiterMesure].
  ///
  /// Ce tick garde son role : rafraichir les ecrans si une mutation de la base
  /// n'a pas notifie par un autre chemin (client DT ou spotter qui ecrit hors
  /// d'un `notifyListeners` de session). Il ne transmet rien et n'invente rien.
  void _syncTick() {
    syncCount++;
    notifyListeners();
  }

  void push(String message) {
    notifications
      ..removeWhere((m) => m == message)
      ..add(message);
    if (notifications.length > 12) {
      notifications.removeRange(0, notifications.length - 12);
    }
    notifyListeners();
  }

  // ------------------------------------------------------------ canal Boss

  /// Notification Boss en cours d'affichage (bandeau rouge plein cadre).
  /// Vraie tant que la derniere notification recue n'a pas ete acquittee par
  /// l'operateur ; le curseur de reprise, lui, vit dans la base.
  bool notificationActive = false;

  /// Derniere notification recue, tout canal confondu (HTTP ou lien local).
  String messageNotification = '';

  /// Acquittement operateur : le bandeau rouge retombe, la notification
  /// reste en base (historique) mais ne remonte plus en plein cadre.
  void acquitterNotification() {
    if (!notificationActive) return;
    notificationActive = false;
    notifyListeners();
  }

  /// ReÃ§oit une notification du canal Boss, quelque soit le chemin :
  /// - **HTTP** (descente directe du serveur central, via unePasseNotifications
  ///   du worker de synchro) ;
  /// - **lien local** (Boss -> serveur -> DT -> excavatrice -> ici, via
  ///   surNotification du client Wi-Fi/BLE) quand la tablette n'a pas de 4G
  ///   mais est a portee de son relais.
  ///
  /// Les deux canaux portent le meme curseur serveur (id) : la base dedoubl-
  /// onne, le bandeau ne remonte que pour un message reelslement nouveau.
  Future<void> recevoirNotificationLocale(Map<String, Object?> notif) async {
    int id = int.tryParse('${notif['id']}') ?? 0;
    final String message = '${notif['message'] ?? ''}';
    final String profil = '${notif['profil'] ?? ''}';
    final String horodatage = '${notif['horodatage'] ?? ''}';
    if (message.isEmpty) return;
    // La base radio peut relayer un ordre SANS id (le Boss l'a tape a la
    // main, ou la station de base ne l'a pas numerote). Le filtre <= curseur
    // le rejetait alors en silence : l'ordre n'apparaissait jamais. On lui
    // attribue ici le prochain numero libre pour qu'il passe le dedoublonnage
    // et s'affiche, sans jamais reculer le curseur.
    if (id <= 0) id = base.derniereIdNotification + 1;
    if (id <= base.derniereIdNotification) return;

    // Relais AVANT le filtrage par profil : un ordre du bureau destinÃ© Ã  un
    // DT (Â« sortie de route, retourner Â») peut d'abord arriver sur
    // l'excavatrice â€” c'est elle qui a la 4G â€” et ne doit pas s'arrÃªter lÃ .
    // Chaque tablette qui reÃ§oit rediffuse Ã  tous ses clients, et c'est
    // chaque CLIENT qui filtre selon son propre profil au moment de la
    // rÃ©ception (appel rÃ©cursif de cette mÃªme mÃ©thode). Le filtre ci-dessous
    // ne garde que le bandeau local, jamais la diffusion.
    await _gatewayWifi?.diffuserNotification(notif);
    await _gatewayBle?.diffuserNotification(notif);

    // Filtrage local : le bandeau ne s'affiche que sur la tablette visÃ©e (ou
    // sur toutes si la notification ne porte pas de profil). Le stockage, lui,
    // est toujours fait : il porte le curseur `derniereIdNotification` qui
    // dedoublonne â€” sans lui, une tablette filtrÃ©e rediffuserait la mÃªme
    // notification Ã  chaque rÃ©ception.
    final int ecrits = base.recevoirNotifications(<NotificationServeur>[
      NotificationServeur(
        id: id,
        message: message,
        profil: profil,
        horodatage: horodatage,
      ),
    ]);
    if (ecrits == 0) return;
    base.journaliser('NOTIFICATION $id recue par lien local');

    final bool cible = profil.isEmpty ||
        profile == null ||
        profil == profile!.code;
    if (!cible) return;

    // Bandeau rouge plein cadre : c'est un ordre du bureau, pas un evenement
    // technique. Il reste jusqu'a l'acquittement de l'operateur.
    messageNotification = message;
    notificationActive = true;
    push('BOSS - $message');
    notifyListeners();
  }
}

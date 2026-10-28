import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Etat de la connexion BLE, tel que l'interface le consomme.
///
/// L'UI ne connait QUE ces quatre etats : elle s'abonne au flux et repeint.
/// Aucune logique de scan, de reconnexion ou de GATT ne fuit vers l'ecran.
enum EtatBle {
  /// Aucun lien, aucune tentative en cours.
  deconnecte('DISCONNECTED', 'deconnecte'),

  /// Recherche d'une excavatrice (scan filtre par service).
  scan('SCANNING', 'recherche'),

  /// Lien en cours d'etablissement (directe ou apres scan).
  connexion('CONNECTING', 'connexion'),

  /// GATT ouvert, notifications actives, handshake a faire ou fait.
  connecte('CONNECTED', 'connecte');

  const EtatBle(this.code, this.libelle);

  /// Code transmis par le natif.
  final String code;

  /// Libelle affiche.
  final String libelle;

  static EtatBle depuisCode(String? code) {
    for (final EtatBle e in EtatBle.values) {
      if (e.code == code) return e;
    }
    return EtatBle.deconnecte;
  }
}

/// Machine d'etat de la connexion BLE native (autoConnect).
///
/// ARCHITECTURE (specification du 27/10) :
///
/// ```
/// [deconnecte] --(adresse connue ?)--> [connexion directe autoConnect]
///      |                                        | echec / timeout
///      +--(adresse inconnue)--> [scan] <--------+
///                                  | service UUID
///                                  v
///                             [connexion] -> [connecte]
///                                  ^               |
///                                  +--- watchdog --+  (15 s sans trame)
/// ```
///
/// CE QUI EST DELEGUE AU NATIF (`BleCentralManager`), et pourquoi :
/// - `connectGatt(autoConnect = true)` : Android garde la demande en attente
///   au niveau de la pile. La reconnexion ne coute AUCUN scan applicatif et
///   aboutit des que l'engin redevient visible.
/// - Persistance de l'appairage (SharedPreferences) : survit au redemarrage
///   de l'application ET de la tablette.
/// - Nettoyage GATT (`disconnect` + `close`) avant chaque tentative : sans
///   lui, Android renvoie `133` (GATT_ERROR) sur la connexion suivante.
///
/// CE QUI RESTE ICI : la POLITIQUE. Quand basculer du direct au scan, quand
/// abandonner, quand oublier. Le natif ne decidant rien, cette politique est
/// testable et documentee en un seul endroit.
class BleMachineEtat extends ChangeNotifier {
  BleMachineEtat({
    MethodChannel? canal,
    EventChannel? flux,
    this.delaiConnexionDirecte = const Duration(seconds: 10),
    this.delaiWatchdog = const Duration(seconds: 15),
    this.dureeScan = const Duration(seconds: 10),
    this.delaiEntreTentatives = const Duration(seconds: 5),
  }) : _canal = canal ?? const MethodChannel('oret/ble_central'),
       _flux = flux ?? const EventChannel('oret/ble_central_events');

  final MethodChannel _canal;
  final EventChannel _flux;

  /// Temps laisse a une connexion DIRECTE avant de basculer sur un scan.
  final Duration delaiConnexionDirecte;

  /// Silence tolere avant de considerer le lien mort (heartbeat absent).
  final Duration delaiWatchdog;

  /// Duree d'une passe de scan.
  final Duration dureeScan;

  /// Repos entre deux cycles complets (evite de saturer la radio).
  final Duration delaiEntreTentatives;

  // ------------------------------------------------------------------ etat

  EtatBle _etat = EtatBle.deconnecte;

  /// Etat courant, lu par l'interface.
  EtatBle get etat => _etat;

  String _detail = '';

  /// Precision affichable (nom de l'engin, motif d'echec).
  String get detail => _detail;

  /// Vrai quand le lien est etabli ET les notifications actives.
  bool get connecte => _etat == EtatBle.connecte;

  /// Adresse de l'excavatrice actuellement visee (ou connectee).
  String? adresse;

  /// Nom annonce (peut etre vide : Android l'omet parfois).
  String nom = '';

  /// Adresse appairee, lue dans la memoire native au demarrage.
  String? get adresseMemorisee => _adresseMemorisee;
  String? _adresseMemorisee;

  String? get nomMemorise => _nomMemorise;
  String? _nomMemorise;

  // --------------------------------------------------------------- canaux

  StreamSubscription<dynamic>? _subFlux;
  StreamSubscription<Uint8List>? _subDonnees;

  final StreamController<Uint8List> _octetsRecus =
      StreamController<Uint8List>.broadcast();

  /// Octets bruts recus de l'excavatrice (le protocole est traite au-dessus).
  Stream<Uint8List> get octetsRecus => _octetsRecus.stream;

  /// Appareils vus pendant le dernier scan.
  final List<AppareilVu> appareilsVus = <AppareilVu>[];

  /// Appele a chaque trame recue du pair (heartbeat implicite).
  void Function()? surTrame;

  Timer? _minuterieWatchdog;
  Timer? _minuterieConnexion;
  Timer? _minuterieCycle;

  bool _arrete = false;
  bool _cycleEnCours = false;

  // ------------------------------------------------------------ cycle de vie

  /// Demarre la machine : branche le flux, lit la memoire, lance le cycle.
  Future<void> demarrer() async {
    if (_arrete) return;
    if (_subFlux != null) return;

    _subFlux = _flux.receiveBroadcastStream().listen(
      _traiterEvenement,
      onError: (Object e) => _journal('flux natif en erreur : $e'),
    );

    // Etat initial : ce que le natif sait deja (adresse appairee, pile).
    final Map<Object?, Object?>? etatPile = await _canal
        .invokeMapMethod<Object?, Object?>('etat');
    _adresseMemorisee = etatPile?['adresseMemorisee'] as String?;
    _nomMemorise = etatPile?['nomMemorise'] as String?;
    if (_nomMemorise != null) nom = _nomMemorise!;

    _journal(
      'initialisation : appairage=${_nomMemorise ?? "(aucun)"} '
      'pile=${etatPile?['active'] == true ? 'active' : 'inactive'}',
    );
    _lancerCycle();
  }

  /// Stoppe tout : cycle, timers, flux.
  Future<void> arreter() async {
    _arrete = true;
    _minuterieCycle?.cancel();
    _minuterieConnexion?.cancel();
    _minuterieWatchdog?.cancel();
    await _subFlux?.cancel();
    _subFlux = null;
    await _subDonnees?.cancel();
    _subDonnees = null;
    await _canal.invokeMethod<Object?>('deconnecter', <String, Object?>{});
  }

  // --------------------------------------------------------------- le cycle

  /// Un cycle complet : directe si possible, sinon scan.
  ///
  /// Ne s'execute jamais en parallele : `_cycleEnCours` protege d'une seconde
  /// passe declenchee par le timer pendant que la premiere attend.
  Future<void> _lancerCycle() async {
    if (_arrete || _cycleEnCours || connecte) return;
    _cycleEnCours = true;
    try {
      final bool ok = await _tenterDirecteOuScan();
      if (!ok && !_arrete && !connecte) {
        // Repos avant le cycle suivant : sans cela, une excavatrice absente
        // ferait tourner la radio en continu.
        _minuterieCycle?.cancel();
        _minuterieCycle = Timer(delaiEntreTentatives, _lancerCycle);
      }
    } finally {
      _cycleEnCours = false;
    }
  }

  /// Connexion directe si une adresse est memorisee, sinon scan.
  Future<bool> _tenterDirecteOuScan() async {
    if (_adresseMemorisee != null && _adresseMemorisee!.isNotEmpty) {
      final bool ok = await _tenterDirecte();
      if (ok) return true;
      _journal('connexion directe sans suite : bascule sur le scan');
    }
    return _tenterScan();
  }

  /// Connexion DIRECTE (autoConnect) sur l'adresse memorisee.
  ///
  /// Le natif rend la main immediatement : la demande reste en attente dans
  /// la pile Android. On attend donc [delaiConnexionDirecte] ici, et si rien
  /// n'est arrive, on bascule sur le scan — c'est exactement la strategie de
  /// repli de la specification.
  Future<bool> _tenterDirecte() async {
    _etat = EtatBle.connexion;
    _detail = 'directe vers ${_nomMemorise ?? _adresseMemorisee}';
    _journal('connexion directe : $_detail');
    notifyListeners();

    final Completer<bool> issue = Completer<bool>();
    _issueConnexion = issue;

    final Object? r = await _canal.invokeMethod<Object?>(
      'connecter_direct',
      <String, Object?>{},
    );
    final Map<Object?, Object?> rep = _lireMap(r);
    if (rep['ok'] != true) {
      _issueConnexion = null;
      _journal('connexion directe refusee : ${rep['erreur']}');
      return false;
    }

    final bool ok = await issue.future.timeout(
      delaiConnexionDirecte,
      onTimeout: () => false,
    );
    _issueConnexion = null;
    if (!ok) {
      // La demande reste en attente cote systeme : on la retire, sinon elle
      // continuerait de consommer la radio pendant le scan.
      await _canal.invokeMethod<Object?>('deconnecter', <String, Object?>{});
      _journal(
        'delai de connexion directe depasse '
        '(${delaiConnexionDirecte.inSeconds} s)',
      );
    }
    return ok;
  }

  /// Scan filtre par service, puis connexion sur l'appareil trouve.
  Future<bool> _tenterScan() async {
    _etat = EtatBle.scan;
    _detail = 'recherche par service ORE';
    _journal('scan demarre (${dureeScan.inSeconds} s)');
    notifyListeners();

    appareilsVus.clear();
    final Completer<AppareilVu?> trouve = Completer<AppareilVu?>();
    _rechercheEnCours = trouve;

    final Object? r = await _canal.invokeMethod<Object?>(
      'scanner',
      <String, Object?>{'dureeMs': dureeScan.inMilliseconds},
    );
    final Map<Object?, Object?> rep = _lireMap(r);
    if (rep['ok'] != true) {
      _rechercheEnCours = null;
      _journal('scan refuse : ${rep['erreur']}');
      return false;
    }

    final AppareilVu? cible = await trouve.future.timeout(
      dureeScan + const Duration(seconds: 2),
      onTimeout: () => null,
    );
    _rechercheEnCours = null;
    if (cible == null) {
      _journal(
        'scan termine : ${appareilsVus.length} appareil(s), aucun retenu',
      );
      return false;
    }

    _adresseMemorisee = cible.adresse;
    nom = cible.nom;
    adresse = cible.adresse;
    _journal(
      'appareil retenu : ${cible.nom.isEmpty ? '(sans nom)' : cible.nom} '
      '(${cible.adresse})',
    );

    _etat = EtatBle.connexion;
    _detail = cible.nom;
    notifyListeners();

    final Completer<bool> issue = Completer<bool>();
    _issueConnexion = issue;
    await _canal.invokeMethod<Object?>('connecter', <String, Object?>{
      'adresse': cible.adresse,
      'nom': cible.nom,
    });
    final bool ok = await issue.future.timeout(
      delaiConnexionDirecte,
      onTimeout: () => false,
    );
    _issueConnexion = null;
    if (!ok) {
      _journal('connexion apres scan echouee');
      await _canal.invokeMethod<Object?>('deconnecter', <String, Object?>{});
    }
    return ok;
  }

  // ------------------------------------------------------------- evenements

  Completer<bool>? _issueConnexion;
  Completer<AppareilVu?>? _rechercheEnCours;

  void _traiterEvenement(dynamic brut) {
    if (brut is! Map) return;
    final Map<Object?, Object?> m = brut;
    final String type = '${m['type']}';

    switch (type) {
      case 'etat':
        _surEtatNatif(EtatBle.depuisCode('${m['etat']}'), '${m['detail']}');
        break;
      case 'appareil':
        final AppareilVu vu = AppareilVu(
          adresse: '${m['adresse']}',
          nom: '${m['nom'] ?? ''}',
          rssi: (m['rssi'] as int?) ?? 0,
        );
        appareilsVus.add(vu);
        // Premier appareil retenu : le natif a deja filtre par service.
        if (_rechercheEnCours != null && !_rechercheEnCours!.isCompleted) {
          _rechercheEnCours!.complete(vu);
        }
        break;
      case 'scanTermine':
        if (_rechercheEnCours != null && !_rechercheEnCours!.isCompleted) {
          _rechercheEnCours!.complete(null);
        }
        break;
      case 'donnees':
        final Object? octets = m['octets'];
        if (octets is Uint8List) {
          _surTrameRecue(octets);
        } else if (octets is List) {
          _surTrameRecue(Uint8List.fromList(octets.cast<int>()));
        }
        break;
    }
  }

  void _surEtatNatif(EtatBle nouvel, String detail) {
    switch (nouvel) {
      case EtatBle.connecte:
        // Le GATT est ouvert mais les notifications peuvent ne pas l'etre
        // encore : `READY` (emis apres l'ecriture du CCCD) est le vrai signal.
        if (detail.startsWith('READY')) {
          _etat = EtatBle.connecte;
          _detail = detail;
          _demarrerWatchdog();
          _issueConnexion?.complete(true);
        }
        break;
      case EtatBle.deconnecte:
        final bool etaitConnecte = _etat == EtatBle.connecte;
        _etat = EtatBle.deconnecte;
        _detail = detail;
        _arreterWatchdog();
        _issueConnexion?.complete(false);
        _issueConnexion = null;
        if (etaitConnecte) {
          _journal('lien perdu ($detail) - reconnexion automatique');
          _lancerCycle();
        }
        break;
      case EtatBle.connexion:
      case EtatBle.scan:
        _etat = nouvel;
        _detail = detail;
        break;
    }
    notifyListeners();
  }

  void _surTrameRecue(Uint8List octets) {
    // TOUTE trame prouve que le lien vit : c'est notre heartbeat.
    _demarrerWatchdog();
    _octetsRecus.add(octets);
    surTrame?.call();
  }

  // -------------------------------------------------------------- watchdog

  /// Redemarre le compte a rebours d'inactivite.
  ///
  /// Le protocole n'a pas de message de battement de coeur dedie : la moindre
  /// trame recue (ACK, ping, relais) vaut preuve de vie. 15 s couvrent deux
  /// cycles de position (5 s) avec de la marge.
  void _demarrerWatchdog() {
    _minuterieWatchdog?.cancel();
    _minuterieWatchdog = Timer(delaiWatchdog, () {
      _journal(
        'watchdog : aucune trame depuis ${delaiWatchdog.inSeconds} s '
        '- deconnexion forcee',
      );
      _canal.invokeMethod<Object?>('deconnecter', <String, Object?>{});
      _etat = EtatBle.deconnecte;
      _detail = 'watchdog';
      notifyListeners();
      _lancerCycle();
    });
  }

  void _arreterWatchdog() {
    _minuterieWatchdog?.cancel();
    _minuterieWatchdog = null;
  }

  // ------------------------------------------------------------------ envoi

  /// Ecrit des octets sur la caracteristique RX.
  Future<bool> envoyer(Uint8List octets) async {
    if (!connecte) return false;
    final Object? r = await _canal.invokeMethod<Object?>(
      'ecrire',
      <String, Object?>{'octets': octets},
    );
    return _lireMap(r)['ok'] == true;
  }

  /// Lecture tolerante d'un resultat de canal (Map Dart ou null).
  static Map<Object?, Object?> _lireMap(Object? valeur) {
    if (valeur is Map) return valeur.cast<Object?, Object?>();
    return const <Object?, Object?>{};
  }

  /// Memorise l'appairage — appele APRES un handshake REUSSI.
  ///
  /// Ne jamais appeler avant : memoriser une adresse qui n'a pas abouti
  /// ferait viser pour toujours un appareil inutilisable.
  Future<void> memoriser(String adresse, String nom) async {
    _adresseMemorisee = adresse;
    _nomMemorise = nom;
    this.nom = nom;
    await _canal.invokeMethod<Object?>('memoriser', <String, Object?>{
      'adresse': adresse,
      'nom': nom,
    });
    _journal('appairage memorise : $nom ($adresse)');
  }

  /// Oublie l'appairage (changement d'engin, deconnexion volontaire).
  Future<void> oublier() async {
    _adresseMemorisee = null;
    _nomMemorise = null;
    await _canal.invokeMethod<Object?>('oublier', <String, Object?>{});
  }

  void _journal(String texte) {
    if (kDebugMode) debugPrint('[BLE] $texte');
    surJournal?.call(texte);
  }

  /// Relaie les lignes techniques vers la supervision de l'interface.
  void Function(String texte)? surJournal;

  static bool get supporte => !kIsWeb && Platform.isAndroid;

  @override
  void dispose() {
    _minuterieCycle?.cancel();
    _minuterieConnexion?.cancel();
    _minuterieWatchdog?.cancel();
    _octetsRecus.close();
    super.dispose();
  }
}

/// Un appareil vu pendant le scan.
class AppareilVu {
  const AppareilVu({
    required this.adresse,
    required this.nom,
    required this.rssi,
  });

  final String adresse;
  final String nom;
  final int rssi;

  @override
  String toString() => 'AppareilVu($adresse, "$nom", $rssi dBm)';
}

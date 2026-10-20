import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

import '../communication/ble/ble_gateway.dart';
import '../communication/ble/ble_protocole.dart';
import '../communication/ble/permissions_ble.dart';
import '../communication/ble/transport_ble.dart';
import '../communication/ble/transport_central.dart';
import '../communication/ble/transport_peripherique.dart';
import '../communication/alertes/alerter.dart';
import '../communication/position/detection_ecart.dart';
import '../communication/position/progression.dart';
import '../communication/position/service_position.dart';
import '../communication/position/session_perle.dart';
import '../communication/wifi/transport_tcp.dart';
import '../communication/wifi/transport_wifi.dart';
import '../communication/wifi/wifi_direct.dart';
import '../communication/wifi/wifi_gateway.dart';
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
/// La synchro **serveur** (CDC §14) est un sujet distinct : c'est
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

  /// Calculateur de progression le long du meme parcours (CDC §4.6) : a
  /// chaque mesure GNSS, la position est projetee sur la polyline recue du
  /// serveur. C'est la valeur reelle que lisent la barre de trajet et la
  /// carte de l'ecran DT (plus aucune simulation).
  final CalculateurProgression progression = CalculateurProgression();

  /// Base de donnees locale. Les listes deroulantes de l'ecran spotter lisent
  /// dedans, et aucune modification ne la contourne. Injectable pour que les
  /// tests y injectent des blasts de demo (`BaseLocale.blastsDemo()`).
  final BaseLocale base;

  /// Worker de synchro serveur (CDC §14) : vide la file `evenements`.
  ///
  /// Construit une seule fois avec la session ; demarre a la connexion, s'arrete
  /// a la deconnexion. Les tests le pilotent par [Synchronisation.unePasse].
  late final Synchronisation synchro;

  /// Ouvre le fichier local (CDC §13) et recharge les donnees du disque.
  ///
  /// Appelee par le splash : echoue silencieusement en « memoire seule » si le
  /// fichier est inaccessible, l'application ne s'arrete jamais la-dessus.
  ///
  /// [demoOffroad] : mode DEMONSTRATION (presentation). Injecte un parcours
  /// fictif dans la base et branche un GPS simulé qui le quitte puis y revient
  /// en boucle — la détection d'écart, l'alerte, le bip et la vibration
  /// fonctionnent exactement comme en production.
  Future<void> ouvrirBase({bool demoOffroad = false}) async {
    await base.ouvrir();
    // Plans deja telecharges lors d'une session precedente : sans ce scan,
    // ils seraient oublies au redemarrage et l'ecran afficherait de nouveau
    // l'URL reseau (ou le plan de la premiere carte) pour chaque RL.
    await base.chargerPlansLocaux();
    demarrerSurveillanceReseau();
    // Première alimentation des listes de login (profils, équipements, DT)
    // avant d'afficher l'écran de connexion. Hors réseau, la base locale
    // existante est conservée et l'utilisateur verra l'état d'attente.
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
    demo = demoOffroad;
    if (demoOffroad) {
      await _preparerDemoOffroad();
    }
    // Les seuils de detection et le GPS se parametrent dans l'ecran
    // Parametres : lus ici une premiere fois, relus par
    // [rechargerParametres] a chaque changement.
    _intervalleGps = _dureeMeta('intervalle_gps_s', 5);
    _filtreGps = _doubleMeta('filtre_distance_gps_m', 5);
    rechargerParametres();
    // Le GPS (§5) part avec la base : ses mesures finissent dans la meme
    // file d'evenements. Sur desktop sans capteur, le service reste
    // silencieux sans jamais planter. L'abonnement aux mesures se pose
    // AVANT le demarrage : la premiere mesure ne peut pas passer a cote.
    //
    // EXCEPTION SPOTTER : sa tablette n'embarque aucun recepteur GNSS. Faire
    // demarrer le service produirait des `GPS_UPDATE` fantomes dans la file
    // d'evenements (compteur « en attente » gonfle par des mesures que
    // l'utilisateur n'a jamais prises). Le mode demo reste prioritaire : il
    // alimente un scenario fictif, quel que soit le profil.
    final bool gpsUtile = demoOffroad ||
        !BaseLocale.estSpotter(profile?.roleCdc ?? '');
    if (gpsUtile) {
      servicePosition = ServicePosition(
        base: base,
        fournisseur: demoOffroad
            ? GpsDemoOffroad(
                figerAlerte: true,
                // Depart du scÃ©nario = le DEPOT connu de la base, en UTM : le
                // DT simulÃ© part du meme point que la carte affiche.
                eastingDepart: _demoEastingDepart,
                northingDepart: _demoNorthingDepart,
              )
            : null,
        intervalle: _intervalleGps,
        filtreDistance: _filtreGps,
      );
      _subMesures ??= servicePosition!.mesures.listen(traiterMesure);
      servicePosition!.demarrer();
    }
    if (demoOffroad) {
      push('Scenario de demonstration : sortie de parcours en cours');
    }
  }

  /// Preparatifs du mode démo : parcours fictif + affectation complète,
  /// pour que la détection d'écart (option B) trouve ses données.
  Future<void> _preparerDemoOffroad() async {
    // Parcours construit entre les points connus de la base (DEPOT -> F5M),
    // convertis en UTM par la meme projection que les mesures GNSS : la carte
    // superpose ainsi parcours, position du DT et drapeau au meme endroit des
    // tuiles OpenStreetMap.
    final ({double lat, double lng})? depot =
        base.positionDe(BaseLocale.codeDepart);
    final ({double lat, double lng})? arrivee = base.positionDe('F5M');
    final (int e0, int n0) = depot == null
        ? (487380, 5056620)
        : Utm.depuisWgs84(depot.lat, depot.lng);
    final (int e1, int n1) = arrivee == null
        ? (493170, 5057120)
        : Utm.depuisWgs84(arrivee.lat, arrivee.lng);
    final StringBuffer trace = StringBuffer('[[$e0,$n0]');
    for (int i = 1; i <= 24; i++) {
      final double t = i / 24;
      trace.write(',[${(e0 + t * (e1 - e0)).round()},'
          '${(n0 + t * (n1 - n0)).round()}]');
    }
    final String parcours = '${trace.toString()}]';
    await base.enregistrerAffectation(<String, String>{
      'destination': 'F5M',
      'dumping_area': 'RomPad 1',
      'parcours': parcours,
    });
    // Le GPS simule part du DEPOT : la position du DT et le parcours vivent
    // au meme endroit de la carte.
    _demoEastingDepart = e0;
    _demoNorthingDepart = n0;
  }
  /// Depart UTM du scÃ©nario GPS de dÃ©mo, pose par [_preparerDemoOffroad]
  /// d'apres le point DEPOT de la base (zone UTM 31 du site de reference).
  int _demoEastingDepart = 487380;
  int _demoNorthingDepart = 5056620;

  /// Service de position du device (CDC §5) : demarre a l'ouverture de la
  /// base, arrete a la fermeture de la session.
  ServicePosition? servicePosition;

  StreamSubscription<PositionTerrain>? _subMesures;

  /// Evenements en attente de transmission vers le serveur (CDC §14, §21).
  int get enAttente => base.nombreEnAttente;

  /// Profil de la session, lu dans `base.profils()` au moment de la connexion.
  Profil? profile;
  String deviceId = '';
  String deviceName = '';
  bool masterConnected = false;
  /// Vrai quand la session tourne en mode DEMONSTRATION (5 taps sur le logo).
  /// Les badges reseau et le texte d'alerte suivent alors des valeurs posees
  /// a la main, pour un rendu de presentation stable et lisible — sans
  /// dependre de la vraie connectivite (Wi-Fi/BLE souvent absents en demo).
  bool demo = false;

  /// Etat de la 4G (§15). Une coupure ne perd rien : elle arrete seulement
  /// les envois, la file reste en place et reprend seule au retablissement.
  bool get gsmOnline => synchro.reseauDisponible;

  set gsmOnline(bool valeur) {
    if (gsmOnline == valeur) return;
    synchro.reseauDisponible = valeur;
    if (valeur) {
      push('4G retablie - reprise de la synchronisation serveur');
      // Une passe immédiate au rétablissement (§15) : la nuée est animée
      // pendant l'échange tant qu'il reste quelque chose à vider.
      unawaited(_passeAvecAnimation());
    } else {
      push('4G perdue - les donnees restent en locale');
      // La nuée retombe : plus rien ne circule vers le serveur.
      synchroActive = false;
    }
    notifyListeners();
  }

  /// Vrai pendant un échange effectif avec le serveur (§14) : la nuée
  /// ([SyncCloudIcon]) s'anime tant que la file PENDING n'est pas vide.
  bool synchroActive = false;

  /// Une passe de synchro avec animation de la nuée : active tant que des
  /// événements restent à transmettre, éteinte dès que la file est vide.
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

  /// Synchro manuelle (nuage du bandeau bas, §14) : relance une passe
  /// complete — evenements sortants PUIS lectures entrantes (referentiels,
  /// blasts, affectation, notifications). Deux appuis rapproches ne
  /// multiplient pas les passes : si une passe tourne deja, l'appui est
  /// simplement ignore — la file et la nuée font foi.
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
  /// rendu son premier resultat (badge Wi-Fi : « pas demarre »).
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
    // initial, les badges resteraient dans l'etat « pas demarre » jusqu'a ce
    // que le reseau change reellement.
    _apiReseau
        .checkConnectivity()
        .then<void>(majConnectivite, onError: (Object _) {});
  }

  void arreterSurveillanceReseau() {
    _subConnectivite?.cancel();
    _subConnectivite = null;
  }

  /// Applique un etat reseau lu chez le systeme (ecouteur et tests).
  ///
  /// C'est la seule porte d'entree de la realite reseau dans la session :
  /// elle alimente le badge Wi-Fi ([etatWifiDevice]) et la 4G
  /// ([gsmOnline], d'ou [etat4G]).
  @visibleForTesting
  void majConnectivite(List<ConnectivityResult> resultats) {
    _connectivite = List<ConnectivityResult>.unmodifiable(resultats);
    final bool enLigne = resultats.any(
      (ConnectivityResult r) =>
          r == ConnectivityResult.wifi ||
          r == ConnectivityResult.mobile ||
          r == ConnectivityResult.ethernet,
    );
    gsmOnline = enLigne;
    // Meme si la 4G ne bouge pas (Wi-Fi -> ethernet), le badge Wi-Fi doit
    // se repeindre : il lit [_connectivite].
    notifyListeners();
  }

  // ---------------------------------------------------------- etats (badges)

  /// Badge Wi-Fi : lien vers le point d'acces Master (CDC §20.1).
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

  /// Badge GPS (§5) : le recepteur externe branche en USB-C est-il lu ?
  ///
  /// Vert des que le service de position produit des mesures (derniere
  /// mesure recue), orange tant que le service tourne sans avoir rien rendu
  /// (acquisition en cours, GPS pas encore fixe), rouge si le service est
  /// arrete ou n'a jamais pu s'abonner (capteur absent, permission refusee).
  EtatCouche get etatGps {
    final ServicePosition? service = servicePosition;
    if (service == null || !service.actif) return EtatCouche.arret;
    return service.derniere == null ? EtatCouche.recherche : EtatCouche.connecte;
  }

  // ------------------------------------------------------ etats simules (demo)
  // En mode DEMONSTRATION, les quatre badges de la barre du DT suivent des
  // valeurs imposees (4G vert, BLE rouge, Wi-Fi rouge, GPS orange) : le rendu
  // de presentation ne depend plus de la vraie connectivite du poste, souvent
  // absente quand on presente hors du site. Hors demo, chaque getter retombe
  // sur l'etat reel mesure ci-dessus.
  /// Badge 4G de la barre DT : vert en demo, sinon [etat4G].
  EtatCouche get etat4GAffiche => demo ? EtatCouche.connecte : etat4G;
  /// Badge BLE de la barre DT : rouge en demo, sinon [etatBle].
  EtatCouche get etatBleAffiche => demo ? EtatCouche.arret : etatBle;
  /// Badge Wi-Fi (hotspot) de la barre DT : rouge en demo, sinon [etatWifiP2p].
  EtatCouche get etatWifiAffiche => demo ? EtatCouche.arret : etatWifiP2p;
  /// Badge GPS de la barre DT : orange en demo (acquisition en cours),
  /// sinon [etatGps].
  EtatCouche get etatGpsAffiche => demo ? EtatCouche.recherche : etatGps;

  /// Badge 4G : retour effectif du serveur (CDC §21).
  ///
  /// Rouge si la boucle de synchro n'a pas ete lancee ou si aucune voie de
  /// retour n'existe, orange le temps d'attendre le premier retour, vert
  /// des que le serveur a repondu au moins une fois.
  EtatCouche get etat4G {
    if (!synchro.actif || !synchro.reseauDisponible) return EtatCouche.arret;
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
  /// `verrouilles` — decide du perimetre du bouton « Envoyer ».
  String get envoiMode => base.envoiMode;

  // ---------------------------------------------------------- parametres

  /// Cadence GPS courante, lue dans `meta.intervalle_gps_s` (§5).
  late Duration _intervalleGps;

  /// Filtre de distance GPS courant, lu dans `meta.filtre_distance_gps_m`.
  late double _filtreGps;

  Duration get intervalleGps => _intervalleGps;
  double get filtreGps => _filtreGps;

  /// Relit les cles `meta` de l'ecran Parametres et les applique **en direct**
  /// : seuils de detection d'ecart (§4) puis, si la cadence ou le filtre GPS
  /// a bouge, redemarrage du service de position (§5).
  ///
  /// `api_base`, `api_token` et `envoi_mode` n'ont pas besoin d'etre
  /// recharge : ils sont relus a chaque envoi. Retourne false si un seuil
  /// incoherent est refuse (sortie >= entree) — la configuration precedente
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
  /// La carte de suivi lit ici la position reelle du device — plus aucune
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
  /// (CDC §4 : le champ `parcours` arrive en metres UTM). Le fuseau est le
  /// meme que celui des mesures GNSS — deduit une seule fois de la premiere
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
    // point projete exact — la ligne verte s'arrete LA, pas au sommet.
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
  /// — le meme que [Utm.versWgs84].
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

  int easting = 320453;
  int northing = 920443;
  int elevation = 260;

  int syncCount = 0;

  /// Progression du trajet, calculee localement (CDC §4.6) par la
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

  /// Alerte poussée par le serveur (option A de la détection d'écart) : le
  /// serveur compare les positions GPS à ses geofences et pose un champ
  /// `alerte` dans `/affectation`. La tablette n'invente rien : elle affiche
  /// le message du serveur, et vide quand rien n'est alerté.
  String get alerteServeur => base.affectation('alerte') ?? '';

  /// Alerte effective de l'ecran DT : l'ecart local (option B) a la priorite,
  /// le repli `alerte` du serveur prend le relais quand aucun parcours n'a
  /// ete recu. Vide = rien a afficher.
  String get alerteCourante {
    // Mode DEMONSTRATION : l'alerte est affichee des l'ouverture de l'ecran,
    // sans attendre que le scenario GPS franchisse le seuil — le rendu de
    // presentation (cadre rouge clignotant, bandeau, bip) est stable du debut
    // a la fin.
    if (demo) {
      return 'DT 05 a fait une sortie de route, retourner et prendre '
          'le chemin du RomPad 1';
    }
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
    detecteurEcart.parcours(base.affectation('parcours'));
    detecteurEcart.evaluer(
      easting: mesure.easting.toDouble(),
      northing: mesure.northing.toDouble(),
      maintenant: mesure.horodatage ?? DateTime.now(),
    );

    // Progression (CDC §4.6) : meme source, meme parser, meme parcours que
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

// Profil excavator (§2.3) : pendant qu'un DT est connecte, chaque position
// GNSS de la perle est envoyee en coordonnees de bloc ET accumulee pour la
// moyenne de la session. La projection dans le repere du bloc n'existe pas
// encore (elle viendra avec l'origine du bloc) : on envoie donc la position
// GNSS telle quelle, comme demande ("les coordonnees de chaque position de
// la perle grace au GNSS").
feederPerle(mesure);

// CHAQUE mesure est notifiee : les tableaux et la carte se repeignent a
    // chaud a chaque changement de position (hot reload des valeurs GNSS),
    // meme sans alerte. Le push ci-dessous notifie deja, sauf sur les
    // branches ou l'etat d'alerte n'a pas change — on assure donc une
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
  /// la perle (profil excavator §2.3). Null tant qu'aucun DT n'est connecte.
  SessionPerle? _sessionPerle;

  /// DT de la session en cours (ex. `TAB2-DT13`), lu par l'ecran excavator.
  String dtConnecte = '';

  /// Nombre de positions accumulees dans la session courante.
  int get positionsPerle => _sessionPerle?.nombre ?? 0;

  /// Moyenne courante de la session (recalculee a chaque mesure), pour
  /// l'affichage : null tant que rien n'a ete accumule.
  MoyennePerle? get moyennePerle => _sessionPerle?.moyenne;

  /// Ouvre une session perle avec le DT qui vient de se connecter, et
  /// journalise l'evenement a l'ecran ("chaque connexion").
  void ouvrirSessionPerle(String dt) {
    dtConnecte = dt;
    _sessionPerle = SessionPerle(dt: dt);
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
    push('Perle : session fermee avec ${session.dt}');
    _sessionPerle = null;
    dtConnecte = '';
    notifyListeners();
  }

  /// Alimente la session perle d'une mesure GNSS (profil excavator §2.3).
  ///
  /// Sans DT connecte, il n'y a rien a envoyer ni a moyenner : la mesure est
  /// ignoree cote perle (elle reste bien sur en file GPS comme toute mesure).
  ///
  /// Envoie la position brute au DT (evenement `POSITION_PERLE`) puis
  /// l'accumule pour la moyenne de la session.
  @visibleForTesting
  void feederPerle(PositionTerrain mesure) {
    final SessionPerle? session = _sessionPerle;
    if (session == null) return;
    // Faute de repere de bloc cote serveur, les coordonnees de bloc sont la
    // position GNSS elle-meme : c'est la position de la perle telle que le
    // GNSS la donne (§2.3).
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
  }

  /// Vrai des que le serveur a pose au moins une affectation.
  bool get affectationRecue => base.toutesAffectations.isNotEmpty;

  /// Horodatage de la validation, affiche en badge par l'ecran DT.
  String? get horodatageAffectation =>
      base.horodatageAffectation('destination');

  /// Derniere synchro serveur terminee, a afficher par la supervision (§21).
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
    // ou un équipement disparu du référentiel local.
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
    // L'identifiant part avec chaque evenement comme source (CDC §12).
    base.declarerAppareil(id);
    push('Connexion établie au point d\'accès Master - $name');
    startSyncLoop();
    // L'état réseau (Wi-Fi/4G) devient réel : on écoute le système au lieu
    // d'un booléen simulé.
    demarrerSurveillanceReseau();
    // La synchro serveur (§14) repart avec la session : les evenements
    // restes en PENDING au precedent demarrage sont deja relus au chargement.
    synchro.demarrer();
    // Le login est valide par les referentiels locaux. Le badge reseau reste
    // pilote par demarrerSurveillanceReseau/etatWifiDevice; il ne doit pas
    // servir de garde d'authentification.
    notifyListeners();
    return true;
  }

  void disconnect() {
    _syncTimer?.cancel();
    _syncTimer = null;
    _timerRssi?.cancel();
    _timerRssi = null;
    // Les couches de collecte s'eteignent : plus rien ne circule vers le DT.
    _gatewayBle?.arreter();
    _gatewayBle = null;
    _clientBle?.arreter();
    _clientBle = null;
    _gatewayWifi?.arreter();
    _gatewayWifi = null;
    _clientWifi?.arreter();
    _clientWifi = null;
    bleActif = false;
    wifiActif = false;
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

  /// Etat BLE expose aux ecrans (CDC §20.2/§20.3).
  bool bleActif = false;
  int tab3Connectes = 0;
  final Map<String, int> rssiTab3 = <String, int>{};

  /// Boucle de supervision RSSI du role DT (CDC §22). Stockee pour etre
  /// annulee a la deconnexion et a la fermeture : sans cela elle tournait
  /// indefiniment en tache de fond apres la fin de la session.
  Timer? _timerRssi;

  /// Identifiant de la passerelle : c'est l'EXCAVATRICE qui la porte
  /// desormais (inversion des roles). Les DT s'y accrochent dans un rayon
  /// de 10 m.
  static const String idGateway = 'EXC-001';

  /// Rayon de connexion du profil excavator, en metres (§2.3).
  ///
  /// Un DT n'est accepte ("pret et charge") que s'il est entre dans ce rayon
  /// autour de l'excavatrice ; il en est deconnecte des qu'il en sort
  /// ("decollage"). Vaut 10 m par defaut, reglable dans `meta`
  /// (`rayon_connexion_m`) depuis l'ecran Parametres.
  ///
  /// Note technique : le plugin BLE `ble_peripheral` n'expose aucune API de
  /// puissance d'emission, donc le rayon n'est pas plafonne a l'emission
  /// (option « a » impossible). Il est applique au **filtrage** (option
  /// « b ») : un DT au-dela du rayon est refuse au handshake, puis
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
  /// reels par defaut —
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
    transport ??= estExcavatrice
        ? TransportBlePeripherique()
        : TransportBleCentral();
    if (estDt) {
      // DT : client BLE, il se connecte a l'excavatrice presente dans son rayon.
      final BleClient client = BleClient(
        transport: transport,
        sourceDevice: deviceId.isEmpty ? 'TAB2-DT' : 'TAB2-$deviceId',
        role: BaseLocale.roleTab2,
      );
      client.surAck = (String eventId) {
        push('BLE ACK recu - $eventId synchronise');
        // File vidée par les ACK : la flèche retombe une fois tout acquitté.
        envoiBleActif = client.fileAttente.isNotEmpty;
        notifyListeners();
      };
      _clientBle = client;
      bleActif = true;
      final bool ok = await client.connecter();
      push(ok
          ? 'BLE connecté à l\'excavatrice - authentifié'
          : 'BLE : excavatrice introuvable - données en file locale');
      // Le DT est pret et charge : il quittera la zone des qu'il decolle
      // (sortie de rayon cote excavatrice, qui le deconnecte).
      // Dès que le lien BLE est vert, la file part automatiquement (CDC §16.1) :
      // la flèche d'échange s'anime pendant l'envoi et l'attente des ACK.
      if (ok) await _retransmettreFileBle();
    } else if (estExcavatrice) {
      // Excavatrice : emet en BLE, accepte les DT entres dans son rayon.
      // En transport reel, demarre l'advertising (le gateway ne le fait pas :
      // c'est le transport qui connait la pile).
      if (transport is TransportBlePeripherique && !bleActif) {
        await transport.demarrerPublicite();
      }
      final BleGateway gateway = BleGateway(
        transport: transport,
        idsAutorises: base.idsDuRole(BaseLocale.roleTab2).toSet(),
        // Rayon de connexion du profil excavator (§2.3) : seuls les DT
        // entres dans ce rayon sont acceptes, et ils sont deconnectes des
        // qu'ils en sortent. Reglable dans `meta` (rayon_connexion_m).
        proximite: ControleurProximite.rayon(rayonM: rayonConnexionM),
      );
      gateway.surEvenement = (String source, Map<String, Object?> evenement) {
        // L'excavatrice recolte, journalise et acquitte.
        base.evenementRecu(evenement);
        push('BLE evenement recu de $source : ${evenement['event_type']}');
        gateway.acquitter(source, '${evenement['event_id']}');
        notifyListeners();
      };
      // Notifiation recue d'un client : relayee a tous les autres clients
      // authentifies (le serveur central n'est pas joignable du terrain —
      // c'est l'excavatrice qui est le relais local du canal Boss).
      gateway.surNotification = (Map<String, Object?> notif) {
        unawaited(recevoirNotificationLocale(notif));
      };
      // Entree dans le rayon : le DT est "pret et charge", on ouvre sa session
      // perle. Sortie de rayon : il "decolle", on gelee la moyenne (§2.3).
      gateway.surConnexion = ouvrirSessionPerle;
      gateway.surDeconnexion = (String _) => fermerSessionPerle();
      _gatewayBle = gateway;
      await gateway.demarrer();
      bleActif = true;
      // Boucle de supervision RSSI (CDC §22). Un seul timer a la fois :
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
      push('BLE passerelle active - ${gateway.idsAutorises.length} appareil(s) autorisé(s)');
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _timerRssi?.cancel();
    _timerRssi = null;
    _gatewayBle?.arreter();
    _clientBle?.arreter();
    _gatewayWifi?.arreter();
    _clientWifi?.arreter();
    // Ferme le groupe Wi-Fi Direct : l'excavatrice cesse d'etre point d'acces.
    WifiDirect.arreter();
    servicePosition?.arreter();
    _subMesures?.cancel();
    _subMesures = null;
    _subConnectivite?.cancel();
    _subConnectivite = null;
    alerter.fermer();
    _syncTimer?.cancel();
    synchro.arreter();
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

  /// État Wi-Fi exposé aux écrans (même pattern que [bleActif]).
  bool wifiActif = false;
  int clientsWifiConnectes = 0;

  /// Port applicatif ORE TRACKING (les deux côtés le connaissent, CDC §7).
  static const int portWifi = 45210;

  /// Démarre la couche Wi-Fi selon le rôle.
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
    if (profil == null) return;
    final bool estExcavatrice = BaseLocale.estTab3(profil.roleCdc);
    final bool estTab1 = BaseLocale.estTab1(profil.roleCdc);
    final bool estDt = BaseLocale.estTab2(profil.roleCdc);
    if (estExcavatrice) {
      // 1. Le reseau d'abord : Wi-Fi Direct cree le groupe, l'excavatrice en
      //    Group Owner. C'est ce qui remplace le hotspot manuel. Sans cette
      //    etape, le serveur TCP ecouterait sur une interface inexistante.
      final bool groupe = await WifiDirect.demarrer(nom: idGateway);
      push(groupe
          ? 'Wi-Fi Direct : groupe $idGateway cree (point d\'acces actif)'
          : 'Wi-Fi Direct indisponible - point d\'acces a activer manuellement');
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
      final List<Map<String, String>> groupes = await WifiDirect.decouvrir();
      final bool vu = groupes.any(
        (Map<String, String> p) => (p['nom'] ?? '').startsWith('ORE-EXC'),
      );
      if (vu) {
        final bool joint = await WifiDirect.connecter(nom: 'ORE-EXC');
        push(joint
            ? 'Wi-Fi Direct : connecte au groupe de l\'excavatrice'
            : 'Wi-Fi Direct : connexion au groupe refusee');
      } else {
        push('Wi-Fi Direct : excavatrice hors portee - donnees en file locale');
      }
      final String prefixe = estTab1 ? 'TAB1' : 'TAB2';
      final WifiClient client = WifiClient(
        transport: transport,
        sourceDevice: deviceId.isEmpty ? '$prefixe-001' : '$prefixe-$deviceId',
        role: estTab1 ? BaseLocale.roleTab1 : BaseLocale.roleTab2,
      );
      client.surAck = (String eventId) {
        push('Wi-Fi ACK reçu - $eventId transmis');
        // File vidée par les ACK : la flèche retombe une fois tout acquitté.
        envoiWifiActif = client.fileAttente.isNotEmpty;
        notifyListeners();
      };
      // Boss -> serveur -> DT (excavatrice) -> ici : notification recue sur
      // le lien local. Meme traitement que la descente HTTP (stockage en
      // base + bandeau), le curseur est le meme donc aucun double affichage.
      client.surNotification = (Map<String, Object?> notif) {
        unawaited(recevoirNotificationLocale(notif));
      };
      // Reconnexion automatique (REQ-008) : à chaque retour de lien, la file
      // repart automatiquement (l'envoi initial est dans _retransmettreFileWifi).
      client.surReconnexion = _retransmettreFileWifi;
      _clientWifi = client;
      wifiActif = true;
      final bool ok = await client.connecter();
      push(ok
          ? 'Wi-Fi connecté à l\'excavatrice - authentifié'
          : 'Wi-Fi : excavatrice introuvable - données en file locale');
      // Reconnexion automatique (REQ-008) : hors portée, le client retente.
      await client.demarrerReconnexionAuto();
      // Dès que le Wi-Fi devient vert, la file part automatiquement (CDC §16.1) :
      // la flèche d'échange s'anime pendant l'envoi et l'attente des ACK.
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
      );
      gateway.surEvenement = (String source, Map<String, Object?> evenement) {
        // Même traitement que le BLE : récolte, journalise, acquitte.
        base.evenementRecu(evenement);
        push('Wi-Fi données reçues de $source : ${evenement['event_type']}');
        gateway.acquitter(source, '${evenement['event_id']}');
        notifyListeners();
      };
      // Notification recue d'un client Wi-Fi (Boss -> serveur -> DT ->
      // excavatrice -> spotter) : stockee et re-diffusee aux autres clients.
      gateway.surNotification = (Map<String, Object?> notif) {
        unawaited(recevoirNotificationLocale(notif));
      };
      _gatewayWifi = gateway;
      await gateway.demarrer();
      wifiActif = true;
      push('Wi-Fi point d\'accès actif - ${gateway.idsAutorises.length} appareil(s) autorisé(s)');
    }
    notifyListeners();
  }

  /// Vrai pendant une transmission effective vers le DT (REQ-007) : la
  /// flèche d'échange ([DataExchangeButton]) s'anime tant que la file Wi-Fi
  /// contient des événements non acquittés.
  bool envoiWifiActif = false;

  /// Idem [envoiWifiActif] pour le lien BLE (TAB 3 -> TAB 2, CDC §7) : la
  /// flèche s'anime tant que la file BLE contient des non-acquittés.
  bool envoiBleActif = false;

  /// Transmet toute la file PENDING de la base au DT via le client BLE.
  /// Appelé dès que le lien BLE devient vert (authentification §9).
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
  /// L'envoi est deja automatique des que le lien est authentifie (§16.1) :
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
  /// Appelé dès que le lien Wi-Fi devient vert (connexion/authentification,
  /// y compris après une reconnexion automatique REQ-008). La flèche reste
  /// animée tant que des événements ne sont pas acquittés (CDC §16.1).
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
  /// ([CalculateurProgression], CDC §4.6) — voir [traiterMesure].
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

  /// Reçoit une notification du canal Boss, quelque soit le chemin :
  /// - **HTTP** (descente directe du serveur central, via unePasseNotifications
  ///   du worker de synchro) ;
  /// - **lien local** (Boss -> serveur -> DT -> excavatrice -> ici, via
  ///   surNotification du client Wi-Fi/BLE) quand la tablette n'a pas de 4G
  ///   mais est a portee de son relais.
  ///
  /// Les deux canaux portent le meme curseur serveur (id) : la base dedoubl-
  /// onne, le bandeau ne remonte que pour un message reelslement nouveau.
  Future<void> recevoirNotificationLocale(Map<String, Object?> notif) async {
    final int id = int.tryParse('${notif['id']}') ?? 0;
    final String message = '${notif['message'] ?? ''}';
    final String profil = '${notif['profil'] ?? ''}';
    final String horodatage = '${notif['horodatage'] ?? ''}';
    if (message.isEmpty || id <= base.derniereIdNotification) return;
    if (profil.isNotEmpty && profile != null && profil != profile!.code) return;

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

    // Bandeau rouge plein cadre : c'est un ordre du bureau, pas un evenement
    // technique. Il reste jusqu'a l'acquittement de l'operateur.
    messageNotification = message;
    notificationActive = true;
    push('BOSS - $message');

    // Relais local : la tablette qui vient de recevoir la notification (DT
    // venant du serveur, ou excavatrice recevant d'un client) la re-diffuse
    // a ses propres clients authentifies. C'est la chaine Boss -> serveur
    // -> DT -> excavatrice -> spotter, chaque maillon relayant le suivant.
    await _gatewayWifi?.diffuserNotification(notif);
    await _gatewayBle?.diffuserNotification(notif);
    notifyListeners();
  }
}

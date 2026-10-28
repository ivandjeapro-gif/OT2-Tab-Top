import 'dart:async';
import 'dart:typed_data';

import 'ble_protocole.dart';
import 'transport_ble.dart';

/// Journaliseur minimal injecte : evite de coupler la couche BLE au reste.
abstract class JournalBle {
  void ligne(String texte);
}

/// Journal en memoire (utilise par les tests et par defaut).
class JournalBleMemoire implements JournalBle {
  final List<String> lignes = <String>[];
  @override
  void ligne(String texte) => lignes.add(texte);
}

/// Gateway BLE : cote TAB 2 (CDC §7, §19 « Module TAB 2 / BLE Gateway »).
///
/// Responsabilites :
/// - accepter plusieurs TAB 3 simultanement (REQ-005) ;
/// - authentifier chaque pair par handshake (CDC §9, REQ-017) : un appareil
///   inconnu est rejete ;
/// - controler la proximite par RSSI avec hysteresis (CDC §8, REQ-006) ;
/// - journaliser connexions, RSSI et decisions (CDC §22).
///
/// La logique est entierement pilotee par [TransportBle] : injecter
/// l'implementation reelle plus tard ne change rien ici.
class BleGateway {
  BleGateway({
    required this.transport,
    required this.idsAutorises,
    JournalBle? journal,
    ControleurProximite? proximite,
    this.maxClients = 5,
    this.idGateway = 'EXC-001',
    this.delaiInactivite = const Duration(seconds: 30),
  })  : _journal = journal ?? JournalBleMemoire(),
        _proximite = proximite ?? ControleurProximite();

  final TransportBle transport;
  final JournalBle _journal;
  final ControleurProximite _proximite;

  /// Identifiant de l'excavatrice, renvoye dans le handshakeOk (§12).
  ///
  /// C'est grace a ce champ que le DT decouvre l'identite reelle de la
  /// machine sous laquelle il est stationne (ex. HYUNDAI-32, EX-2000),
  /// sans saturer le paquet d'advertising radio.
  final String idGateway;

  /// Identifiants enrroles autorises a se connecter (CDC §9, REQ-017).
  final Set<String> idsAutorises;

  /// Limite de connexions simultanees (CDC §7 : a calibrer sur le materiel).
  final int maxClients;

  final Map<String, LienBle> _liens = <String, LienBle>{};

  /// Horodatage de la derniere trame recue de chaque pair.
  ///
  /// Sert au DELAI D'INACTIVITE. Sans lui, un client dont le Bluetooth est
  /// coupe ne provoque AUCUN `onDone` : la pile Android cote peripherique
  /// ne signale pas toujours la fermeture, et la gateway continuait de
  /// compter ce client comme connecte. Consequence observee le 27/10 : le DT
  /// affichait « en recherche » (orange) alors que l'excavatrice restait
  /// VERTE, avec un DT fantome dans `clientsConnectes` et une session perle
  /// ouverte pour personne.
  final Map<String, DateTime> _derniereActivite = <String, DateTime>{};

  /// Duree de silence toleree avant de considerer un pair parti.
  ///
  /// 30 s : un DT vivant envoie au moins un ping toutes les quelques
  /// secondes, et le relais de positions passe toutes les 10 s. Le delai
  /// couvre largement une micro-coupure radio sans couper un lien sain.
  final Duration delaiInactivite;


  final Map<String, StreamSubscription<Uint8List>> _subs =
      <String, StreamSubscription<Uint8List>>{};
  StreamSubscription<LienBle>? _subEntrants;

  /// Appareils actuellement acceptes.
  List<String> get clientsConnectes => _liens.keys.toList(growable: false);

  /// Dernier RSSI par appareil (UI supervision CDC §21).
  Map<String, int> get rssiClients =>
      Map<String, int>.unmodifiable(_proximite.dernierRssi);

  bool get actif => _subEntrants != null;

  /// Demarre l'ecoute des connexions entrantes.
  Future<void> demarrer() async {
    if (actif) return;
    _subEntrants = transport.liensEntrants().listen(_accueilLien);
    _journal.ligne('BLE gateway demarre - ${idsAutorises.length} appareil(s) '
        'autorise(s)');
  }

  Future<void> _accueilLien(LienBle lien) async {
    // REQ-005 : borne le nombre de clients simultanes.
    if (_liens.length >= maxClients) {
      _journal.ligne('BLE refus ${lien.idPair} : limite de $maxClients '
          'clients atteinte');
      await lien.fermer();
      return;
    }
    // Chaque lien attend son handshake avant d'etre accepte. On s'abonne
    // IMMEDIATEMENT au flux de messages (sans quoi le handshake envoye par le
    // client pendant l'attente serait perdu) et on traite le premier message
    // recu comme le handshake attendu (CDC §9).
    final Completer<Map<String, Object?>?> handshake =
        Completer<Map<String, Object?>?>();
    StreamSubscription<Uint8List>? subAttente;
    subAttente = lien.messages.listen(
      (Uint8List octets) {
        if (!handshake.isCompleted) handshake.complete(BleProtocole.decoder(octets));
      },
      onError: (Object e) {
        if (!handshake.isCompleted) handshake.complete(null);
      },
      onDone: () {
        if (!handshake.isCompleted) handshake.complete(null);
      },
    );
    Map<String, Object?>? message;
    try {
      message = await handshake.future
          .timeout(const Duration(seconds: 5), onTimeout: () => null);
    } finally {
      await subAttente.cancel();
    }
    if (message == null || message['type'] != BleProtocole.typeHandshake) {
      _journal.ligne('BLE refus ${lien.idPair} : pas de handshake');
      await lien.fermer();
      return;
    }
    final String id = '${message['source_device'] ?? ''}';
    final String role = '${message['role'] ?? ''}';

    // Authentification (CDC §9, REQ-017) : id inconnu => rejet immediat.
    if (!idsAutorises.contains(id)) {
      _journal.ligne('BLE refus $id : appareil non enrrole');
      await lien.envoyer(
          BleProtocole.encoder(BleProtocole.handshakeKo(motif: 'non enrôle')));
      // Laisse la livraison partir avant de couper le lien.
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await lien.fermer();
      return;
    }

    // Proximite (CDC §8, REQ-006) : RSSI declare par le client dans le
    // handshake (le peripherique Android ne peut pas le mesurer), sinon
    // mesure locale si le lien la propose, sinon refus.
    final Object? rssiDeclare = message['rssi'];
    final int? rssi = rssiDeclare is int
        ? rssiDeclare
        : (int.tryParse('$rssiDeclare') ?? await lien.mesurerRssi());
    final VerdictProximite verdict = rssi == null
        ? VerdictProximite.refus
        : _proximite.evaluerPremierContact(id, rssi);
    // Mémorise la déclaration dans le lien : la supervision (rafraichirRssi)
    // la relira tant que le client ne renvoie pas de mesure plus récente.
    if (rssi != null && lien is LienDeclaratif) {
      (lien as LienDeclaratif).rssiDeclare = rssi;
    }
    _journal.ligne('BLE $id RSSI $rssi -> $verdict');
    if (verdict == VerdictProximite.refus) {
      _journal.ligne('BLE refus $id : hors zone de proximite');
      await lien.envoyer(BleProtocole.encoder(
          BleProtocole.handshakeKo(motif: 'hors zone')));
      // Laisse la livraison partir avant de couper le lien.
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await lien.fermer();
      return;
    }

    _liens[id] = lien;
    _derniereActivite[id] = DateTime.now();
    _subs[id] = lien.messages.listen(
      (Uint8List octets) {
        // Chaque trame prouve que le pair est vivant (voir [delaiInactivite]).
        _derniereActivite[id] = DateTime.now();
        _traiterMessage(id, octets);
      },
      onDone: () => _deconnexion(id),
      onError: (Object _) => _deconnexion(id),
    );
    await lien.envoyer(
        BleProtocole.encoder(BleProtocole.handshakeOk(gatewayId: idGateway)));
    _journal.ligne('BLE $id connecte (role $role, RSSI $rssi)');
    // Un DT vient d'entrer dans le rayon : la couche au-dessus ouvre sa
    // session perle (§2.3).
    surConnexion?.call(id);
  }

  /// Traite un message applicatif d'un TAB 3 deja authentifie.
  ///
  /// TAMPON D'ASSEMBLAGE PAR PAIR : un message JSON depasse souvent la MTU
  /// negociee et arrive en PLUSIEURS notifications GATT. Chaque fragment
  /// decode seul donne soit un JSON partiel valide (sans `type`), soit rien :
  /// la gateway le jetait en « type inconnu null » et le message etait PERDU.
  /// Observe le 22/10 : 16 fragments en 46 ms, dont la provision du reseau
  /// Wi-Fi — le DT ne changeait donc jamais de reseau (badge rouge).
  ///
  /// On accumule les octets du pair jusqu'a ce qu'ils forment un JSON complet
  /// portant un `type`. Purge si le tampon depasse 8 ko (message corrompu).
  final Map<String, BytesBuilder> _tampons = <String, BytesBuilder>{};

  void _traiterMessage(String id, Uint8List octets) {
    final BytesBuilder tampon =
        _tampons[id] ??= BytesBuilder(copy: false);
    if (tampon.length + octets.length > 8192) {
      // Flux incoherent (jamais de JSON complet) : on repart de zero plutot
      // que de grossir sans fin.
      tampon.clear();
      _journal.ligne('BLE $id : tampon purge (>8 ko sans message complet)');
    }
    tampon.add(octets);
    final Uint8List cumul = tampon.toBytes();
    final Map<String, Object?>? message = BleProtocole.decoder(cumul);
    if (message == null || message['type'] == null) {
      // Fragment incomplet : on GARDE le cumul et on attend la suite.
      // (toBytes() ne vide pas le builder : on le reconstruit pour conserver
      // exactement les octets deja recus.)
      _tampons[id] = BytesBuilder(copy: false)..add(cumul);
      return;
    }
    // Message complet : le tampon repart vide pour le suivant.
    _tampons.remove(id);
    _dispatcherMessage(id, message);
  }

  /// Route un message COMPLET (type present) vers son traitement.
  void _dispatcherMessage(String id, Map<String, Object?> message) {
    switch (message['type']) {
      case BleProtocole.typeEvenement:
        surEvenement?.call(id, message);
        // Acquittement systematique (CDC §17) : c'est lui qui purge la file
        // du pair. Sans lui, l'excavatrice renvoyait le meme evenement a
        // chaque passe de relais et le DT le recevait en boucle.
        final Object? eventId = message['event_id'];
        if (eventId != null) {
          unawaited(acquitter(id, '$eventId'));
        }
        break;
      case BleProtocole.typeAck:
        // Accuse du pair pour ce que CE cote lui a pousse (relais, provision).
        // Il n'a pas de file propre a purger ici, mais sans cette branche le
        // moindre ACK partait en « type inconnu » et l'accroc du dialogue
        // etait invisible au journal (CDC §22).
        _journal.ligne('BLE ACK recu de $id pour ${message['event_id']}');
        break;
      case BleProtocole.typeNotification:
        surNotification?.call(message);
        break;
      case BleProtocole.typePing:
        // Reponse echo : le client en deduit la vitalite du lien.
        _liens[id]?.envoyer(BleProtocole.encoder(
            BleProtocole.ping('EXC-001')));
        break;
      case BleProtocole.typeProvision:
        // Le client confirme avoir recu le reseau : on journalise, la
        // connexion Wi-Fi se fait de son cote.
        surProvisionRecue?.call(id, message);
        break;
      default:
        _journal.ligne('BLE $id : type inconnu ${message['type']}');
    }
  }

  /// Branche la reception des evenements metier du TAB 3 (CDC §10/§11).
  /// L'ACK est pose automatiquement apres l'appel (CDC §17).
  void Function(String source, Map<String, Object?> evenement)? surEvenement;

  /// Notification serveur recue d'un client (diffusee par la session DT
  /// excavatrice vers tous ses clients, dont TAB 1 spotter).
  void Function(Map<String, Object?> notification)? surNotification;

  /// Appareil accepte dans la zone : la couche au-dessus ouvre la session de
  /// collecte (profil excavator §2.3 : "chaque connexion" journalisee).
  void Function(String source)? surConnexion;

  /// Appareil sorti de la zone ou deconnecte : la couche au-dessus gelee la
  /// moyenne de la session et la remet a zero (§2.3 : "decollage").
  void Function(String source)? surDeconnexion;

  /// Provisionnement reseau : pousse le SSID et le mot de passe du point
  /// d'acces a un client deja authentifie.
  ///
  /// N'est envoye qu'**apres** le handshake : un appareil non enrole ne peut
  /// donc jamais recevoir les identifiants du reseau. Rend le nombre de
  /// clients servis.
  Future<int> provisionner(Map<String, Object?> provision) async {
    if (provision.isEmpty) return 0;
    final Uint8List octets = BleProtocole.encoder(provision);
    int servis = 0;
    for (final MapEntry<String, LienBle> e in _liens.entries) {
      try {
        await e.value.envoyer(octets);
        servis++;
      } catch (_) {
        // Lien parti entre-temps : le client redemandera au prochain contact.
      }
    }
    if (servis > 0) {
      _journal.ligne('PROVISION envoyee a $servis client(s)');
    }
    return servis;
  }

  /// Un client confirme avoir recu la provision reseau.
  void Function(String source, Map<String, Object?> message)? surProvisionRecue;

  /// Envoie un ACK a l'appareil source (idempotence CDC §17).
  Future<void> acquitter(String source, String eventId) async {
    final LienBle? lien = _liens[source];
    if (lien == null) return;
    await lien.envoyer(BleProtocole.encoder(BleProtocole.ack(eventId: eventId)));
  }

  /// Pousse une enveloppe d'evenement a TOUS les clients authentifies.
  ///
  /// Pendant BLE de `WifiGateway.diffuserEvenement` : l'excavatrice relaie
  /// vers le DT ce qu'elle a collecte (saisies spotter, positions).
  Future<void> diffuserEvenement(Map<String, Object?> evenement) async {
    final Uint8List octets = BleProtocole.encoder(evenement);
    for (final LienBle lien in List<LienBle>.of(_liens.values)) {
      try {
        await lien.envoyer(octets);
      } catch (_) {
        // Lien parti : l'evenement reste en file, la passe suivante reprend.
      }
    }
  }

  /// Diffuse une notification a TOUS les clients authentifies (le DT
  /// excavatrice relaie le canal serveur vers les spotters presents).
  Future<void> diffuserNotification(Map<String, Object?> notification) async {
    for (final LienBle lien in List<LienBle>.of(_liens.values)) {
      try {
        await lien.envoyer(BleProtocole.encoder(notification));
      } catch (_) {
        // Lien parti : le client rattrapera par le curseur HTTP.
      }
    }
  }

  void _deconnexion(String id) {
    _derniereActivite.remove(id);
    _subs.remove(id)?.cancel();
    // Tampon de fragmentation du pair : inutile, et il garderait une demi-
    // trame d'une session future.
    _tampons.remove(id);
    _liens.remove(id);
    _proximite.oublier(id);
    _journal.ligne('BLE $id deconnecte');
    // Sortie de zone ("decollage") : la couche au-dessus gelee la moyenne
    // de la session perle et la remet a zero.
    surDeconnexion?.call(id);
  }

  /// Mesure et journalise le RSSI de chaque lien (CDC §22) : a appeler
  /// periodiquement par la boucle de supervision.
  Future<void> rafraichirRssi() async {
    // Copie : `_deconnexion` retire des entrees de `_liens` pendant qu'on
    // l'itere (ConcurrentModificationException sinon).
    for (final MapEntry<String, LienBle> e
        in List<MapEntry<String, LienBle>>.of(_liens.entries)) {
      final DateTime maintenant = DateTime.now();
      final DateTime? derniere = _derniereActivite[e.key];

      // WATCHDOG D'INACTIVITE **AVANT** la mesure RSSI : `mesurerRssi`
      // peut echouer (ou bloquer) sur un lien deja mort, et c'est
      // precisement le cas d'un Bluetooth coupe. On tranche donc d'abord.
      if (derniere != null && maintenant.difference(derniere) > delaiInactivite) {
        _journal.ligne('BLE ${e.key} silencieux depuis '
            '${maintenant.difference(derniere).inSeconds} s - considere '
            'deconnecte');
        try {
          await e.value.fermer();
        } catch (_) {
          // Lien deja casse : la fermeture est un bonus, la deconnexion
          // logique ci-dessous est ce qui compte.
        }
        _deconnexion(e.key);
        continue;
      }

      final int? rssi = await e.value.mesurerRssi();
      if (rssi != null) {
        final VerdictProximite v = _proximite.evaluer(e.key, rssi);
        if (v == VerdictProximite.refus) {
          _journal.ligne('BLE ${e.key} sort de la zone (RSSI $rssi)');
          await e.value.fermer();
          _deconnexion(e.key);
        }
      }
    }
  }

  Future<void> arreter() async {
    await _subEntrants?.cancel();
    _subEntrants = null;
    for (final String id in List<String>.of(_liens.keys)) {
      await _liens[id]?.fermer();
      _deconnexion(id);
    }
    _journal.ligne('BLE gateway arrete');
  }
}

/// Client BLE : cote TAB 3 (CDC §7, §19 « Module TAB 3 / BLE Client »).
///
/// Responsabilites :
/// - decouvrir TAB 2, s'y connecter, se faire authentifier par handshake ;
/// - envoyer ses evenements et attendre l'ACK (retransmission sinon) ;
/// - stocker localement ce qui n'est pas acquitte (CDC §16.1) ;
/// - se reconnecter automatiquement (REQ-018).
class BleClient {
  BleClient({
    required this.transport,
    required this.sourceDevice,
    required this.role,
    JournalBle? journal,
  }) : _journal = journal ?? JournalBleMemoire();

  final TransportBle transport;
  final JournalBle _journal;

  /// Identifiant applicatif de ce TAB 3 (CDC §9).
  final String sourceDevice;

  /// Role CDC de l'appareil (`ROLE_TAB3`).
  final String role;

  LienBle? _lien;
  StreamSubscription<Uint8List>? _sub;
  bool _authentifie = false;

  /// Flux de messages du lien courant, memorise parce que
  /// `TransportBle` le type en `Stream<Uint8List>` alors que les
  /// implementations reelles exposent un stream **large** (souscription GATT) :
  /// se reconnecter au meme flux par le getter le rendrait non-listenable.
  Stream<Uint8List>? _messages;

  /// Boucle de reconnexion automatique (REQ-018) : null tant qu'elle n'est
  /// pas demandee ou qu'elle a ete arretee.
  Timer? _timerReconnexion;
  bool _reconnexionEnCours = false;

  /// Delai entre deux tentatives quand l'excavatrice n'est pas a portee.
  /// Reglable pour le banc et les tests (attente courte).
  Duration cadenceReconnexion = const Duration(seconds: 10);

  /// File locale des evenements non acquittes (CDC §16.1).
  final List<Map<String, Object?>> fileAttente = <Map<String, Object?>>[];

  /// Identifiant BLE (adresse) de l'excavatrice sur laquelle la derniere
  /// connexion a REUSSI.
  ///
  /// C'est la memoire de la reconnexion : au lancement suivant, on vise
  /// directement cette adresse au lieu de repartir en scan a l'aveugle (ou
  /// l'on risquait de s'accrocher a une AUTRE tablette du site). Vide tant
  /// qu'aucune connexion n'a abouti, ou si l'appairage Android a renouvele
  /// l'adresse private — le scan prend alors le relais.
  String? _adresseMemoire;

  /// Nom annonce par l'excavatrice a la derniere connexion reussie.
  String nomAppareil = '';

  /// RSSI du dernier scan : repli quand le lien refuse de le mesurer.
  ///
  /// Constante a 0 : le plugin Android ne rend pas le RSSI d'un lien GATT, et
  /// `AppareilBle.rssi` n'est disponible qu'au scan — negligeable ici, le
  /// gateway revalide le RSSI lui-meme cote peripherique.
  static const int _dernierRssi = 0;

  bool get connecte => _lien != null && _authentifie && _lien!.ouvert;

  /// Evenements acquittes par TAB 2 : la couche au-dessus purge la file.
  void Function(String eventId)? surAck;

  /// Notification serveur recue sur le lien BLE (Boss -> DT -> spotter) :
  /// la couche au-dessus la stocke en base et l'affiche (bandeau rouge).
  void Function(Map<String, Object?> notification)? surNotification;

  /// Evenement metier recu d'une autre tablette (relais de l'excavatrice) :
  /// la couche au-dessus le stocke pour l'envoyer ensuite au serveur.
  void Function(Map<String, Object?> evenement)? surEvenement;

  /// Provisionnement reseau recu : `{ssid, mot_de_passe, adresse, port}`.
  /// La couche au-dessus s'y connecte puis confirme par [confirmerProvision].
  void Function(Map<String, Object?> provision)? surProvision;

  /// Demarre la decouverte et la connexion a l'excavatrice (emetteur).
  ///
  /// Retourne des que connecte et authentifie, ou apres [delai] si
  /// l'excavatrice est absente — l'appelant retentera, ou [demarrerReconnexionAuto]
  /// s'en charge (REQ-018). Ne leve pas d'exception.
  Future<bool> connecter({Duration delai = const Duration(seconds: 10)}) async {
    // Point de passage unique : une reinscription ici rendrait la reconnexion
    // d'un lien deja authentifie impossible. Une tentative precedente en echec
    // a deja nettoye son lien, rien a refaire.
    if (connecte) return true;

    AppareilBle? cible;

    // RECONNEXION DETERMINISTE (27/10).
    //
    // `_adresseMemoire` retient l'identifiant BLE (adresse) de l'appareil
    // sur lequel la derniere connexion a REUSSI. On le vise directement :
    // plus de scan a l'aveugle, plus de risque de s'accrocher a une autre
    // tablette. Le scan reste le repli quand rien n'est encore memorise
    // (premiere connexion) ou quand l'adresse a change (appairage Android
    // qui renouvelle l'adresse privee).
    if (_adresseMemoire != null && _adresseMemoire!.isNotEmpty) {
      _journal.ligne('BLE reconnexion a $nomAppareil ($_adresseMemoire)');
      try {
        _lien = await transport
            .connecter(AppareilBle(
              id: _adresseMemoire!,
              nom: nomAppareil,
              rssi: 0,
            ))
            .timeout(delai);
        if (await _authentifier(delai)) return true;
        // Echec sur l'adresse memorisee : on repasse par le scan.
        await _lien?.fermer();
        _lien = null;
      } catch (e) {
        _journal.ligne('BLE reconnexion directe echouee ($e) - scan');
        _lien = null;
      }
    }

    // Le filtre `withServices` rate l'excavatrice de façon intermittente
    // (Android 15, diagnostic 21/10) : on tolère donc un premier scan à
    // vide en réessayant, au lieu d'abandonner la tentative. Deux passes
    // de `delai/2` suffisent et la reconnexion automatique reprendra de
    // toute façon.
    //
    // SELECTION AUTOMATIQUE PAR PUISSANCE RSSI (MULTI-ENGINS) :
    //
    // Sur une mine avec plusieurs excavatrices emettant le meme service,
    // on ne prend JAMAIS le premier appareil au hasard : on ecoute une
    // fenetre rapide (1.5 s max) et on choisit la pelle ayant le signal
    // le plus fort (le RSSI le plus eleve), c'est-a-dire celle sous
    // laquelle le camion est stationne.
    final List<AppareilBle> vus = <AppareilBle>[];
    final DateTime finFenetre =
        DateTime.now().add(const Duration(milliseconds: 1500));
    await for (final AppareilBle a
        in transport.scanner().timeout(delai, onTimeout: (sink) => sink.close)) {
      vus.add(a);
      _journal.ligne(
        'BLE vu ${a.nom.isEmpty ? '(sans nom)' : a.nom} (${a.id}, '
        'service=${a.serviceOre}, rssi=${a.rssi})',
      );
      // Signal tres fort (ex: >= -55 dBm, camion colle sous le godet) :
      // decision instantanee sans attendre la fin du delai.
      if ((a.rssi ?? -100) >= -55) {
        break;
      }
      if (DateTime.now().isAfter(finFenetre)) {
        break;
      }
    }
    _journal.ligne('BLE scan termine : ${vus.length} appareil(s) vu(s)');
    if (vus.isNotEmpty) {
      // Tri par signal RSSI decroissant : signal le plus fort en tete.
      vus.sort((a, b) => (b.rssi ?? -100).compareTo(a.rssi ?? -100));
      cible = vus.first;
    }
    if (cible == null) {
      _journal.ligne(
        'BLE aucune excavatrice annoncee (service ORE ou nom ORE-EXC) : '
        'nouvelle tentative plus tard',
      );
      return false;
    }
    // L'appareil retenu devient la cible des reconnexions suivantes.
    _adresseMemoire = cible.id;
    nomAppareil = cible.nom;
    _journal.ligne(
      'BLE ${cible.nom.isEmpty ? cible.id : cible.nom} retenue '
      '(${cible.id}, service=${cible.serviceOre})',
    );
    try {
      _lien = await transport.connecter(cible).timeout(delai);
    } catch (e) {
      _journal.ligne('BLE connexion echouee : $e');
      return false;
    }
    return _authentifier(delai);
  }

  /// Passes du handshake sur un lien deja etabli, puis abonnement de session.
  ///
  /// Extrait de [connecter] pour que la RECONNEXION DIRECTE (adresse
  /// memorisee) passe exactement par le meme chemin, sans dupliquer la
  /// logique d'authentification et de retransmission de file.
  Future<bool> _authentifier(Duration delai) async {
    // On s'abonne aux messages AVANT d'envoyer le handshake : la reponse
    // (HANDSHAKE_OK ou KO) peut partir pendant qu'on ecrit, un message recu
    // avant l'abonnement serait perdu (deja observe sur le banc).
    final Stream<Uint8List> messages = _lien!.messages;
    _messages = messages;
    final Completer<bool> verdict = Completer<bool>();
    StreamSubscription<Uint8List>? subHandshake;
    subHandshake = messages.listen(
      (Uint8List octets) {
        final Map<String, Object?>? m = BleProtocole.decoder(octets);
        if (m == null) return;
        if (m['type'] == BleProtocole.typeHandshakeOk) {
          final String gatewayId = '${m['gateway_id'] ?? ''}';
          if (gatewayId.isNotEmpty) {
            nomAppareil = gatewayId;
            _journal.ligne('BLE identifie aupres de $gatewayId');
          }
          if (!verdict.isCompleted) verdict.complete(true);
        } else if (m['type'] == BleProtocole.typeHandshakeKo) {
          _journal.ligne('BLE refus par TAB 2 : ${m['motif']}');
          if (!verdict.isCompleted) verdict.complete(false);
        }
      },
      onDone: () {
        if (!verdict.isCompleted) verdict.complete(false);
      },
      onError: (Object _) {
        if (!verdict.isCompleted) verdict.complete(false);
      },
    );
    try {
      // Le peripherique (TAB 2) ne peut pas mesurer le RSSI sur Android :
      // le client mesure son propre lien central et le declare ici (CDC §8).
      // En cas d'échec, le RSSI du scan sert de repli ; sinon le gateway
      // gardera son verdict null (refus, reconnexion plus tard).
      final int rssiLien = await _lien!.mesurerRssi() ?? _dernierRssi;
      await _lien!.envoyer(BleProtocole.encoder(BleProtocole.handshake(
          sourceDevice: sourceDevice, role: role, rssi: rssiLien)));
      final bool ok = await verdict.future
          .timeout(delai, onTimeout: () => false);
      if (!ok) {
        // Refus ou silence : le lien est nettoie, l'appelant retentera.
        await _lien!.fermer();
        _lien = null;
        return false;
      }
    } catch (e) {
      _journal.ligne('BLE handshake echoue : $e');
      await _lien?.fermer();
      _lien = null;
      return false;
    } finally {
      await subHandshake.cancel();
    }
    _authentifie = true;
    // Meme reference de flux que le handshake (`_messages`) : un flux simple
    // ne s'ecoute qu'une fois.
    _sub = (_messages ?? messages).listen(
      _traiterMessage,
      // Coupure en cours de session (eloignement, radio) : le lien est
      // abandonne et la boucle de reconnexion reprend la main (REQ-018).
      onDone: _lienPerdu,
      onError: (Object _) => _lienPerdu(),
    );
    _journal.ligne('BLE $sourceDevice authentifie par TAB 2');
    _demarrerBattement();
    // Retransmission de la file en attente (CDC §16.1).
    for (final Map<String, Object?> e in List<Map<String, Object?>>.of(
        fileAttente)) {
      await envoyer(e);
    }
    return true;
  }

  /// Cadence du battement de coeur envoye a l'excavatrice.
  ///
  /// POURQUOI CE PING (27/10). Le protocole ne produisait aucun trafic entre
  /// deux positions (5 s) ni entre deux relais (10 s). Or l'excavatrice a un
  /// watchdog d'inactivite de 30 s : sans battement, une session immobile
  /// pouvait etre coupee alors que le lien etait sain. Et cote client, rien
  /// ne permettait de distinguer « lien mort » de « engin silencieux ».
  ///
  /// Le gateway REPONDAIT deja au PING par un echo (`typePing`) ; il
  /// manquait seulement l'emetteur.
  static const Duration cadenceBattement = Duration(seconds: 8);

  Timer? _battement;

  /// Demarre (ou redemarre) l'emission periodique du PING.
  void _demarrerBattement() {
    _battement?.cancel();
    _battement = Timer.periodic(cadenceBattement, (_) async {
      final LienBle? lien = _lien;
      if (lien == null || !connecte) {
        _battement?.cancel();
        _battement = null;
        return;
      }
      try {
        await lien.envoyer(
          BleProtocole.encoder(BleProtocole.ping(sourceDevice)),
        );
      } catch (_) {
        // Lien parti : `_lienPerdu` fera le menage a la prochaine erreur.
      }
    });
  }

  void _arreterBattement() {
    _battement?.cancel();
    _battement = null;
  }

  /// Le lien est tombe : on oublie l'etat authentifie pour que `connecte`
  /// redevienne faux, et la surveillance reprendra la reconnexion.
  ///
  /// La file [fileAttente] est conservee : rien n'est perdu, elle repartira
  /// a la prochaine authentification (CDC §16.1).
  void _lienPerdu() {
    _arreterBattement();
    if (!_authentifie && _lien == null) return;
    _authentifie = false;
    _lien = null;
    // Oubli de l'adresse : quand le DT s'eloigne, le prochain tour
    // re-evalue la pelle la plus proche par RSSI, permettant au camion de
    // changer d'excavatrice de facon transparente sans rester bloque.
    _adresseMemoire = null;
    _journal.ligne('BLE lien perdu avec $sourceDevice - file conservee');
  }

  /// Reconnecte automatiquement, indefiniment, tant que [arreter] n'a pas ete
  /// appele (REQ-018).
  ///
  /// Sans cette boucle, le DT reste bloque sur l'echec du demarrage : il faut
  /// fermer et rouvrir la session pour retenter, alors que l'utilisateur
  /// s'attend a ce que le lien revienne seul en approchant de l'excavatrice.
  void demarrerReconnexionAuto({Duration? cadence}) {
    if (cadence != null) cadenceReconnexion = cadence;
    _timerReconnexion?.cancel();
    _timerReconnexion = Timer.periodic(cadenceReconnexion, (_) async {
      if (connecte || _reconnexionEnCours) return;
      _reconnexionEnCours = true;
      try {
        final bool ok = await connecter();
        if (ok) _journal.ligne('BLE reconnecte a l\'excavatrice');
      } catch (e) {
        _journal.ligne('BLE reconnexion echouee : $e');
      } finally {
        _reconnexionEnCours = false;
      }
    });
  }

  /// Vrai si la boucle de reconnexion automatique tourne.
  bool get reconnexionAuto => _timerReconnexion != null;

  /// Envoie un evenement et l'ajoute a la file jusqu'a l'ACK (CDC §14/§17).
  ///
  /// Un evenement trop volumineux pour la MTU GATT (512 o) ne doit PAS
  /// casser le lien : observe en terrain (payload de 25 654 o, 21/10),
  /// l'exception remontait jusqu'au demarrage de la couche (« BLE
  /// indisponible ») et bloquait tout. Il est retire de la file BLE et
  /// marque pour le canal serveur — la synchro 4G le transmettra.
  Future<void> envoyer(Map<String, Object?> evenement) async {
    final String eventId = '${evenement['event_id']}';
    final Uint8List octets;
    try {
      octets = BleProtocole.encoder(evenement);
    } catch (_) {
      fileAttente.removeWhere((Map<String, Object?> e) =>
          '${e['event_id']}' == eventId);
      surTropLong?.call(eventId);
      _journal.ligne('BLE $eventId trop volumineux pour la MTU - laisse au '
          'canal serveur');
      return;
    }
    fileAttente.add(evenement);
    final LienBle? lien = _lien;
    if (lien == null || !connecte) {
      _journal.ligne('BLE $eventId en file (non connecte)');
      return;
    }
    await lien.envoyer(octets);
    _journal.ligne('BLE $eventId envoye, ACK attendu');
  }

  /// Un evenement depasse la MTU BLE et a ete ecarte du canal : la couche
  /// au-dessus peut journaliser et laisser la synchro serveur le porter.
  void Function(String eventId)? surTropLong;

  /// Confirme a l'excavatrice que le reseau a ete rejoint : elle peut cesser
  /// de renvoyer la provision a ce client.
  Future<void> confirmerProvision() async {
    final LienBle? lien = _lien;
    if (lien == null || !connecte) return;
    await lien.envoyer(BleProtocole.encoder(
      <String, Object?>{'type': BleProtocole.typeProvision, 'ok': true},
    ));
  }

  /// Tampon d'assemblage : un message JSON depasse souvent la MTU et arrive
  /// en plusieurs notifications GATT. Chaque fragment decode seul n'a pas de
  /// `type` (ou n'est pas du JSON) et etait jeté — la provision du reseau
  /// Wi-Fi faisait partie des messages perdus, d'ou le badge Wi-Fi rouge
  /// permanent (mesure du 22/10).
  final BytesBuilder _tampon = BytesBuilder(copy: false);

  void _traiterMessage(Uint8List octets) {
    if (_tampon.length + octets.length > 8192) {
      _tampon.clear();
      _journal.ligne('BLE tampon purge (>8 ko sans message complet)');
    }
    _tampon.add(octets);
    final Uint8List cumul = _tampon.toBytes();
    final Map<String, Object?>? m = BleProtocole.decoder(cumul);
    if (m == null || m['type'] == null) {
      // Fragment incomplet : on conserve les octets et on attend la suite.
      _tampon
        ..clear()
        ..add(cumul);
      return;
    }
    _tampon.clear();
    if (m['type'] == BleProtocole.typeAck) {
      final String id = '${m['event_id']}';
      fileAttente.removeWhere((e) => e['event_id'] == id);
      surAck?.call(id);
      _journal.ligne('BLE ACK recu pour $id');
    } else if (m['type'] == BleProtocole.typeProvision) {
      // L'excavatrice nous donne le reseau a rejoindre : la couche au-dessus
      // ouvre la connexion Wi-Fi, puis en accuse reception.
      surProvision?.call(m);
      _journal.ligne(
          'BLE provision recue : SSID ${m['ssid']}');
    } else if (m['type'] == BleProtocole.typeEvenement) {
      // Relais recu (excavatrice -> DT) : la couche au-dessus le stocke puis
      // l'acquitte, ce qui purge la file du relais.
      surEvenement?.call(m);
      _journal.ligne('BLE evenement recu ${m['event_type']}');
    } else if (m['type'] == BleProtocole.typeNotification) {
      // Boss -> serveur -> DT -> ici : notification recue par le lien local,
      // la couche au-dessus la stocke et l'affiche (bandeau rouge).
      surNotification?.call(m);
      _journal.ligne('BLE notification recue #${m['id']}');
    }
  }

  Future<void> arreter() async {
    _arreterBattement();
    _timerReconnexion?.cancel();
    _timerReconnexion = null;
    await _sub?.cancel();
    _sub = null;
    await _lien?.fermer();
    _lien = null;
    _authentifie = false;
  }
}

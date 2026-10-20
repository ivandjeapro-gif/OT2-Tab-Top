import 'dart:async';

import 'package:flutter/foundation.dart';

import 'transport_wifi.dart';
import 'wifi_protocole.dart';

/// Journaliseur minimal injecté (même pattern que le BLE).
abstract class JournalWifi {
  void ligne(String texte);
}

/// Journal en mémoire (tests et défaut).
class JournalWifiMemoire implements JournalWifi {
  final List<String> lignes = <String>[];
  @override
  void ligne(String texte) => lignes.add(texte);
}

/// Gateway Wi-Fi : côté TAB 2 (CDC §6, §19 « point d'accès Master »).
///
/// Responsabilités (REQ-007/008) :
/// - héberger le réseau, accepter les TAB 1 à portée (40 m) ;
/// - authentifier chaque pair par handshake (REQ-017) ;
/// - collecter les événements du spotter et les acquitter (§17) ;
/// - journaliser connexions et décisions (§22).
///
/// Logique pilotée par [TransportWifi] : le vrai point d'accès ( sockets TCP)
/// se branche derrière la même interface, le banc de tests la simule.
class WifiGateway {
  WifiGateway({
    required this.transport,
    required this.idsAutorises,
    JournalWifi? journal,
    this.maxClients = 5,
    this.idGateway = 'TAB2-001',
  }) : _journal = journal ?? JournalWifiMemoire();

  final TransportWifi transport;
  final JournalWifi _journal;

  /// Identifiants enrôlés autorisés (CDC §9, REQ-017).
  final Set<String> idsAutorises;

  /// Limite de connexions simultanées.
  final int maxClients;

  /// Identifiant de la passerelle, inscrit dans les ACK (§12).
  final String idGateway;

  final Map<String, LienWifi> _liens = <String, LienWifi>{};
  final Map<String, StreamSubscription<Uint8List>> _subs =
      <String, StreamSubscription<Uint8List>>{};
  StreamSubscription<LienWifi>? _subEntrants;

  /// Pairs actuellement authentifiés.
  List<String> get clientsConnectes => _liens.keys.toList(growable: false);

  bool get actif => _subEntrants != null;

  /// Démarre l'écoute des connexions entrantes.
  Future<void> demarrer() async {
    if (actif) return;
    _subEntrants = transport.liensEntrants().listen(_accueilLien);
    _journal.ligne('Wi-Fi gateway demarre - ${idsAutorises.length} appareil(s) '
        'autorise(s)');
  }

  Future<void> _accueilLien(LienWifi lien) async {
    if (_liens.length >= maxClients) {
      _journal.ligne('Wi-Fi refus ${lien.idPair} : limite de $maxClients');
      await lien.fermer();
      return;
    }
    // Même leçon que le BLE : s'abonner AVANT que le pair n'envoie son
    // handshake, sinon la réponse arrive avant l'écoute et le blocage suit.
    final Completer<Map<String, Object?>?> handshake =
        Completer<Map<String, Object?>?>();
    StreamSubscription<Uint8List>? subAttente;
    subAttente = lien.messages.listen(
      (Uint8List octets) {
        if (!handshake.isCompleted) {
          handshake.complete(WifiProtocole.decoder(octets));
        }
      },
      onError: (Object _) {
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
    if (message == null || message['type'] != WifiProtocole.typeHandshake) {
      _journal.ligne('Wi-Fi refus ${lien.idPair} : pas de handshake');
      await lien.fermer();
      return;
    }
    final String id = '${message['source_device'] ?? ''}';
    final String role = '${message['role'] ?? ''}';

    // Authentification (REQ-017) : id inconnu => rejet immédiat.
    if (!idsAutorises.contains(id)) {
      _journal.ligne('Wi-Fi refus $id : appareil non enrôlé');
      await _envoyerEtFermer(
          lien, WifiProtocole.handshakeKo(motif: 'non enrôlé'));
      return;
    }

    _liens[id] = lien;
    _subs[id] = lien.messages.listen(
      (Uint8List octets) => _traiterMessage(id, octets),
      onDone: () => _deconnexion(id),
      onError: (Object _) => _deconnexion(id),
    );
    await lien.envoyer(
        WifiProtocole.encoder(WifiProtocole.handshakeOk(gatewayId: idGateway)));
    _journal.ligne('Wi-Fi $id connecte (role $role)');
  }

  void _traiterMessage(String id, Uint8List octets) {
    final Map<String, Object?>? message = WifiProtocole.decoder(octets);
    if (message == null) {
      _journal.ligne('Wi-Fi $id : message illisible ignore');
      return;
    }
    switch (message['type']) {
      case WifiProtocole.typeEvenement:
        surEvenement?.call(id, message);
        break;
      case WifiProtocole.typeNotification:
        surNotification?.call(message);
        break;
      case WifiProtocole.typePing:
        _liens[id]?.envoyer(
            WifiProtocole.encoder(WifiProtocole.pong(idGateway)));
        break;
      default:
        _journal.ligne('Wi-Fi $id : type inconnu ${message['type']}');
    }
  }

  /// Branche la réception des événements métier du TAB 1 (CDC §10/§11).
  void Function(String source, Map<String, Object?> evenement)? surEvenement;

  /// Notification serveur recue sur ce lien (Boss -> DT -> spotter) : le
  /// client la relaie a la couche au-dessus, qui la stocke et l'affiche.
  void Function(Map<String, Object?> notification)? surNotification;

  /// Diffuse une notification a TOUS les clients authentifies (le DT relaie
  /// le canal serveur vers les spotters presents dans son rayon).
  Future<void> diffuserNotification(Map<String, Object?> notification) async {
    for (final LienWifi lien in _liens.values) {
      try {
        await lien.envoyer(WifiProtocole.encoder(notification));
      } catch (_) {
        // Lien parti : la notification suivante repassera, le client
        // rattrapera aussi par le curseur HTTP a sa prochaine synchro.
      }
    }
  }

  /// Pousse une enveloppe d'événement à TOUS les clients authentifiés.
  ///
  /// C'est le pendant serveur de [WifiClient.envoyer] : l'excavatrice relaie
  /// vers le DT ce qu'elle a collecté (spotter, positions). Les clients
  /// acquittent chacun comme d'habitude ; l'émetteur original, lui, a déjà
  /// reçu son ACK au moment de la collecte, donc il ne le rejouera pas.
  Future<void> diffuserEvenement(Map<String, Object?> evenement) async {
    for (final LienWifi lien in _liens.values) {
      try {
        await lien.envoyer(WifiProtocole.encoder(evenement));
      } catch (_) {
        // Lien parti : l'événement reste en file, la passe suivante le
        // reprendra pour les clients encore présents.
      }
    }
  }

  /// Envoie un ACK à l'appareil source (idempotence CDC §17).
  Future<void> acquitter(String source, String eventId) async {
    final LienWifi? lien = _liens[source];
    if (lien == null) return;
    await lien.envoyer(WifiProtocole.encoder(WifiProtocole.ack(eventId: eventId)));
  }

  Future<void> _envoyerEtFermer(LienWifi lien, Map<String, Object?> message) async {
    try {
      await lien.envoyer(WifiProtocole.encoder(message));
      await Future<void>.delayed(const Duration(milliseconds: 10));
    } catch (_) {
      // Le pair est peut-être déjà parti : on ferme quand même.
    }
    await lien.fermer();
  }

  void _deconnexion(String id) {
    _subs.remove(id)?.cancel();
    _liens.remove(id);
    _journal.ligne('Wi-Fi $id deconnecte');
  }

  Future<void> arreter() async {
    await _subEntrants?.cancel();
    _subEntrants = null;
    for (final String id in List<String>.of(_liens.keys)) {
      await _liens[id]?.fermer();
      _deconnexion(id);
    }
    await transport.arreter();
    _journal.ligne('Wi-Fi gateway arrete');
  }
}

/// Client Wi-Fi : côté TAB 1 (CDC §6, REQ-008).
///
/// Responsabilités :
/// - trouver le point d'accès ORE-EXC (excavatrice), s'y associer, passer le
///   handshake ;
/// - envoyer ses événements et attendre l'ACK, garder en file sinon (§16.1) ;
/// - se reconnecter automatiquement en cas de coupure (REQ-008).
class WifiClient {
  WifiClient({
    required this.transport,
    required this.sourceDevice,
    required this.role,
    JournalWifi? journal,
    this.delaiReconnexion = const Duration(seconds: 5),
  }) : _journal = journal ?? JournalWifiMemoire();

  final TransportWifi transport;
  final JournalWifi _journal;

  /// Identifiant applicatif de ce TAB 1 (CDC §9).
  final String sourceDevice;

  /// Role CDC de l'appareil.
  final String role;

  /// Délai avant une nouvelle tentative de reconnexion (REQ-008).
  final Duration delaiReconnexion;

  LienWifi? _lien;
  StreamSubscription<Uint8List>? _sub;
  Timer? _minuterieReconnexion;
  bool _authentifie = false;
  bool _arrete = false;

  /// File locale des événements non acquittés (CDC §16.1).
  final List<Map<String, Object?>> fileAttente = <Map<String, Object?>>[];

  bool get connecte => _lien != null && _authentifie && _lien!.ouvert;

  /// Evenements acquittés par TAB 2 : la couche au-dessus purge la file.
  void Function(String eventId)? surAck;

  /// Evenement metier recu d'une autre tablette (relais du DT ou de
  /// l'excavatrice) : la couche au-dessus le stocke localement pour l'envoyer
  /// ensuite au serveur. Sans ce canal, les donnees du spotter s'arreteraient
  /// a la tablette relais.
  void Function(Map<String, Object?> evenement)? surEvenement;

  /// Notification serveur recue sur le lien local (Boss -> DT -> spotter) :
  /// meme canal que la descente HTTP, mais instantane quand le DT est a
  /// portee. La couche au-dessus la stocke en base et l'affiche.
  void Function(Map<String, Object?> notification)? surNotification;

  /// Lien redevenu opérationnel après une reconnexion (REQ-008) : le
  /// propriétaire (session) retransmet sa file PENDING à ce moment.
  VoidCallback? surReconnexion;
  ///
  /// Retourne true si authentifié, false si TAB 2 est absent ou refuse —
  /// sans exception, l'appelant décide de retenter (REQ-008).
  Future<bool> connecter({Duration delai = const Duration(seconds: 10)}) async {
    if (_arrete) return false;
    ReseauWifi? cible;
    await for (final ReseauWifi r in transport.scanner()) {
      if (r.ssid.startsWith('ORE-EXC')) {
        cible = r;
        break;
      }
    }
    if (cible == null) {
      _journal.ligne('Wi-Fi TAB2 non trouve : nouvelle tentative plus tard');
      return false;
    }
    try {
      _lien = await transport.connecter(cible).timeout(delai);
    } catch (e) {
      _journal.ligne('Wi-Fi connexion echouee : $e');
      return false;
    }
    // Abonnement AVANT le handshake (même pattern que le BLE, déjà observe).
    final Stream<Uint8List> messages = _lien!.messages;
    final Completer<bool> verdict = Completer<bool>();
    StreamSubscription<Uint8List>? subHandshake;
    subHandshake = messages.listen(
      (Uint8List octets) {
        final Map<String, Object?>? m = WifiProtocole.decoder(octets);
        if (m == null) return;
        if (m['type'] == WifiProtocole.typeHandshakeOk) {
          if (!verdict.isCompleted) verdict.complete(true);
        } else if (m['type'] == WifiProtocole.typeHandshakeKo) {
          _journal.ligne('Wi-Fi refus par TAB 2 : ${m['motif']}');
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
      await _lien!.envoyer(WifiProtocole.encoder(WifiProtocole.handshake(
          sourceDevice: sourceDevice, role: role)));
      final bool ok = await verdict.future.timeout(delai, onTimeout: () => false);
      if (!ok) {
        await _lien!.fermer();
        _lien = null;
        return false;
      }
    } catch (e) {
      _journal.ligne('Wi-Fi handshake echoue : $e');
      return false;
    } finally {
      await subHandshake.cancel();
    }
    _authentifie = true;
    _sub = messages.listen(_traiterMessage);
    _journal.ligne('Wi-Fi $sourceDevice authentifie par TAB 2');
    // Retransmission de la file en attente (CDC §16.1, REQ-008).
    for (final Map<String, Object?> e in List<Map<String, Object?>>.of(
        fileAttente)) {
      await envoyer(e);
    }
    return true;
  }

  /// Active la reconnexion automatique (REQ-008) : surveille le lien et
  /// retente tant que [connecter] échoue. Sans effet si déjà activée.
  Future<void> demarrerReconnexionAuto() async {
    if (_arrete || _minuterieReconnexion != null) return;
    _minuterieReconnexion =
        Timer.periodic(delaiReconnexion, (_) => _surveiller());
  }

  Future<void> _surveiller() async {
    if (_arrete || connecte) return;
    _authentifie = false;
    _sub?.cancel();
    _sub = null;
    _lien?.fermer();
    _lien = null;
    final bool ok = await connecter();
    if (ok) surReconnexion?.call();
  }

  /// Adopte un lien déjà établi par une autre voie que [connecter] (ex. :
  /// tests, reprise d'un lien conservé) : s'abonne aux messages, marque
  /// authentifié, puis envoie l'événement et attend l'ACK.
  Future<void> envoyerParLien(
      LienWifi lien, Map<String, Object?> evenement) async {
    _lien = lien;
    _authentifie = true;
    await _sub?.cancel();
    _sub = lien.messages.listen(_traiterMessage);
    await envoyer(evenement);
  }

  /// Envoie un événement et l'ajoute à la file jusqu'à l'ACK (CDC §14/§17).
  Future<void> envoyer(Map<String, Object?> evenement) async {
    final String eventId = '${evenement['event_id']}';
    fileAttente.add(evenement);
    final LienWifi? lien = _lien;
    if (lien == null || !connecte) {
      _journal.ligne('Wi-Fi $eventId en file (non connecte)');
      return;
    }
    await lien.envoyer(WifiProtocole.encoder(evenement));
    _journal.ligne('Wi-Fi $eventId envoye, ACK attendu');
  }

  void _traiterMessage(Uint8List octets) {
    final Map<String, Object?>? m = WifiProtocole.decoder(octets);
    if (m == null) return;
    if (m['type'] == WifiProtocole.typeAck) {
      final String id = '${m['event_id']}';
      fileAttente.removeWhere((e) => e['event_id'] == id);
      surAck?.call(id);
      _journal.ligne('Wi-Fi ACK recu pour $id');
    } else if (m['type'] == WifiProtocole.typeEvenement) {
      // Relais recu (excavatrice -> DT, ou DT -> spotter) : la couche
      // au-dessus le stocke puis l'acquitte pour purger la file du relais.
      surEvenement?.call(m);
      _journal.ligne('Wi-Fi evenement recu ${m['event_type']}');
    } else if (m['type'] == WifiProtocole.typeNotification) {
      // Boss -> serveur -> DT -> ici : la notification arrive par le lien
      // local, la couche au-dessus la stocke et l'affiche (bandeau rouge).
      surNotification?.call(m);
      _journal.ligne('Wi-Fi notification recue #${m['id']}');
    }
  }

  Future<void> arreter() async {
    _arrete = true;
    _minuterieReconnexion?.cancel();
    _minuterieReconnexion = null;
    await _sub?.cancel();
    _sub = null;
    await _lien?.fermer();
    _lien = null;
    _authentifie = false;
  }
}

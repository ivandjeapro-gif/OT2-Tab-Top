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
  })  : _journal = journal ?? JournalBleMemoire(),
        _proximite = proximite ?? ControleurProximite();

  final TransportBle transport;
  final JournalBle _journal;
  final ControleurProximite _proximite;

  /// Identifiants enrroles autorises a se connecter (CDC §9, REQ-017).
  final Set<String> idsAutorises;

  /// Limite de connexions simultanees (CDC §7 : a calibrer sur le materiel).
  final int maxClients;

  final Map<String, LienBle> _liens = <String, LienBle>{};
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
    _subs[id] = lien.messages.listen(
      (Uint8List octets) => _traiterMessage(id, octets),
      onDone: () => _deconnexion(id),
      onError: (Object _) => _deconnexion(id),
    );
    await lien.envoyer(
        BleProtocole.encoder(BleProtocole.handshakeOk(gatewayId: 'EXC-001')));
    _journal.ligne('BLE $id connecte (role $role, RSSI $rssi)');
    // Un DT vient d'entrer dans le rayon : la couche au-dessus ouvre sa
    // session perle (§2.3).
    surConnexion?.call(id);
  }

  /// Traite un message applicatif d'un TAB 3 deja authentifie.
  void _traiterMessage(String id, Uint8List octets) {
    final Map<String, Object?>? message = BleProtocole.decoder(octets);
    if (message == null) {
      _journal.ligne('BLE $id : message illisible ignore');
      return;
    }
    switch (message['type']) {
      case BleProtocole.typeEvenement:
        surEvenement?.call(id, message);
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
  /// Retourne le message recu pour que l'appellant pose l'ACK.
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
    for (final LienBle lien in _liens.values) {
      try {
        await lien.envoyer(BleProtocole.encoder(evenement));
      } catch (_) {
        // Lien parti : l'evenement reste en file, la passe suivante reprend.
      }
    }
  }

  /// Diffuse une notification a TOUS les clients authentifies (le DT
  /// excavatrice relaie le canal serveur vers les spotters presents).
  Future<void> diffuserNotification(Map<String, Object?> notification) async {
    for (final LienBle lien in _liens.values) {
      try {
        await lien.envoyer(BleProtocole.encoder(notification));
      } catch (_) {
        // Lien parti : le client rattrapera par le curseur HTTP.
      }
    }
  }

  void _deconnexion(String id) {
    _subs.remove(id)?.cancel();
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
    for (final MapEntry<String, LienBle> e in _liens.entries) {
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

  /// File locale des evenements non acquittes (CDC §16.1).
  final List<Map<String, Object?>> fileAttente = <Map<String, Object?>>[];

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
  /// l'excavatrice est absente — l'appelant retentera (REQ-018). Ne leve pas
  /// d'exception.
  Future<bool> connecter({Duration delai = const Duration(seconds: 10)}) async {
    AppareilBle? cible;
    await for (final AppareilBle a in transport.scanner()) {
      if (a.nom.startsWith('ORE-EXC')) {
        cible = a;
        break;
      }
    }
    if (cible == null) {
      _journal.ligne('BLE excavatrice non trouvee : nouvelle tentative plus tard');
      return false;
    }
    try {
      _lien = await transport.connecter(cible).timeout(delai);
    } catch (e) {
      _journal.ligne('BLE connexion echouee : $e');
      return false;
    }
    // On s'abonne aux messages AVANT d'envoyer le handshake : la reponse
    // (HANDSHAKE_OK ou KO) peut partir pendant qu'on ecrit, un message recu
    // avant l'abonnement serait perdu (deja observe sur le banc).
    final Stream<Uint8List> messages = _lien!.messages;
    final Completer<bool> verdict = Completer<bool>();
    StreamSubscription<Uint8List>? subHandshake;
    subHandshake = messages.listen(
      (Uint8List octets) {
        final Map<String, Object?>? m = BleProtocole.decoder(octets);
        if (m == null) return;
        if (m['type'] == BleProtocole.typeHandshakeOk) {
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
      final int? rssiLien =
          await _lien!.mesurerRssi() ?? cible.rssi;
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
      return false;
    } finally {
      await subHandshake.cancel();
    }
    _authentifie = true;
    _sub = messages.listen(_traiterMessage);
    _journal.ligne('BLE $sourceDevice authentifie par TAB 2');
    // Retransmission de la file en attente (CDC §16.1).
    for (final Map<String, Object?> e in List<Map<String, Object?>>.of(
        fileAttente)) {
      await envoyer(e);
    }
    return true;
  }

  /// Envoie un evenement et l'ajoute a la file jusqu'a l'ACK (CDC §14/§17).
  Future<void> envoyer(Map<String, Object?> evenement) async {
    final String eventId = '${evenement['event_id']}';
    fileAttente.add(evenement);
    final LienBle? lien = _lien;
    if (lien == null || !connecte) {
      _journal.ligne('BLE $eventId en file (non connecte)');
      return;
    }
    await lien.envoyer(BleProtocole.encoder(evenement));
    _journal.ligne('BLE $eventId envoye, ACK attendu');
  }

  /// Confirme a l'excavatrice que le reseau a ete rejoint : elle peut cesser
  /// de renvoyer la provision a ce client.
  Future<void> confirmerProvision() async {
    final LienBle? lien = _lien;
    if (lien == null || !connecte) return;
    await lien.envoyer(BleProtocole.encoder(
      <String, Object?>{'type': BleProtocole.typeProvision, 'ok': true},
    ));
  }

  void _traiterMessage(Uint8List octets) {
    final Map<String, Object?>? m = BleProtocole.decoder(octets);
    if (m == null) return;
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
    await _sub?.cancel();
    _sub = null;
    await _lien?.fermer();
    _lien = null;
    _authentifie = false;
  }
}

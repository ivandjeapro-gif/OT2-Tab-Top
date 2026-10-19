import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

/// Protocole applicatif BLE entre TAB 3 et TAB 2 (CDC §7, §9, §12).
///
/// Chaque message applicatif voyage dans une seule notification/écriture GATT,
/// encodé en UTF-8 JSON. Format conforme au CDC §12 :
/// ```json
/// {
///   "event_id": "UUID",
///   "gateway_id": "TAB2-001",
///   "source_device": "TAB3-004",
///   "event_type": "TRIP_START",
///   "timestamp": "2026-10-02T11:32:18Z",
///   "payload": {}
/// }
/// ```
///
/// La taille d'une notification GATT est bornee (par defaut 512 octets en BLE
/// 4.2+ apres negotiation MTU) : le payload doit rester compact. Un message
/// trop long est refuse des la construction, jamais envoye partiellement.
class BleProtocole {
  BleProtocole._();

  /// Version du protocole (CDC §23). Inscrite dans le handshake.
  static const String version = '1.0';

  /// Types de messages applicatifs.
  static const String typeHandshake = 'HANDSHAKE';
  static const String typeHandshakeOk = 'HANDSHAKE_OK';
  static const String typeHandshakeKo = 'HANDSHAKE_KO';
  static const String typeEvenement = 'EVENEMENT';
  static const String typeNotification = 'NOTIFICATION';
  static const String typeAck = 'ACK';
  static const String typePing = 'PING';

  /// Longueur maximale d'un message encodé (garde-fou MTU).
  static const int octetsMax = 512;

  /// Encode un message applicatif en octets, pret pour le canal GATT.
  static Uint8List encoder(Map<String, Object?> message) {
    final List<int> octets = utf8.encode(jsonEncode(message));
    if (octets.length > octetsMax) {
      throw StateError('Message BLE trop long : ${octets.length} octets '
          '(max $octetsMax). Payload a reduire.');
    }
    return Uint8List.fromList(octets);
  }

  /// Décode un lot d'octets recus du canal GATT en message applicatif.
  ///
  /// Retourne null (et non une exception) sur un message illisible : un pair
  /// buggue ne doit pas faire tomber la couche.
  static Map<String, Object?>? decoder(Uint8List octets) {
    try {
      final Object? decode = jsonDecode(utf8.decode(octets));
      if (decode is Map<String, Object?>) return decode;
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Evenement metier conforme au CDC §12 (type applicatif EVENEMENT).
  static Map<String, Object?> evenement({
    required String eventId,
    required String gatewayId,
    required String sourceDevice,
    required String eventType,
    required DateTime timestamp,
    Map<String, Object?> payload = const <String, Object?>{},
  }) =>
      <String, Object?>{
        'type': typeEvenement,
        'event_id': eventId,
        'gateway_id': gatewayId,
        'source_device': sourceDevice,
        'event_type': eventType,
        'timestamp': timestamp.toUtc().toIso8601String(),
        'payload': payload,
      };

  /// Handshake emis par le TAB 3 des la connexion GATT (CDC §9) :
  /// identification + role, pour que TAB 2 decide d'autoriser ou non.
  /// [rssi] : RSSI mesure cote client (le peripherique Android ne peut pas
  /// le lire sur son propre lien), utilisé par TAB 2 pour la proximite.
  static Map<String, Object?> handshake({
    required String sourceDevice,
    required String role,
    int? rssi,
  }) =>
      <String, Object?>{
        'type': typeHandshake,
        'protocole': version,
        'source_device': sourceDevice,
        'role': role,
        if (rssi != null) 'rssi': rssi,
      };

  /// Verdict du gateway apres identification + controle de proximite.
  static Map<String, Object?> handshakeOk({required String gatewayId}) =>
      <String, Object?>{
        'type': typeHandshakeOk,
        'gateway_id': gatewayId,
        'protocole': version,
      };

  static Map<String, Object?> handshakeKo({required String motif}) =>
      <String, Object?>{
        'type': typeHandshakeKo,
        'motif': motif,
        'protocole': version,
      };

  /// Acquittement d'un evenement recu par TAB 2 (idempotence par event_id).
  static Map<String, Object?> ack({required String eventId}) =>
      <String, Object?>{'type': typeAck, 'event_id': eventId};

  /// Notification serveur transmise sur le lien (Boss -> DT -> spotter).
  /// Meme structure que la descente HTTP, compacte pour la MTU GATT.
  static Map<String, Object?> notification({
    required int id,
    required String message,
    String profil = '',
  }) =>
      <String, Object?>{
        'type': typeNotification,
        'id': id,
        'profil': profil,
        'message': message,
      };

  /// Battement de coeur : permet aussi au client de mesurer le RSSI par lien.
  static Map<String, Object?> ping(String source) =>
      <String, Object?>{'type': typePing, 'source': source,
        'timestamp': DateTime.now().toUtc().toIso8601String()};
}

/// Resultat d'un controle de proximite (CDC §8).
enum VerdictProximite { autorise, refus, aSurveiller }

/// Controleur de proximite RSSI avec hysteresis (CDC §8.1).
///
/// Le RSSI n'est pas une mesure exacte de distance (CDC §8) : il varie de
/// plusieurs dB d'une mesure a l'autre au meme endroit. L'hysteresis consiste
/// a utiliser deux seuils distincts :
/// - un seuil d'ENTREE large (signal fort) : on n'entre pas dans la zone par
///   accident sur un pic de signal ;
/// - un seuil de SORTIE strict (signal faible) : on ne sort pas de la zone
///   sur un simple creux de mesure.
///
/// L'etat (dedans / dehors) est memorise : c'est lui qui decide quel seuil
/// s'applique. Sans cette memoire, la hysteresis ne fait rien.
class ControleurProximite {
  ControleurProximite({
    this.seuilEntreeDbm = -70,
    this.seuilSortieDbm = -80,
    this.mesuresPourDecider = 3,
  })  : assert(seuilEntreeDbm > seuilSortieDbm),
        assert(mesuresPourDecider >= 1);

  /// Variante exprimee **en metres** : la zone de connexion du profil
  /// excavator est specifiee en distance (« rayon de 10 m »), pas en dBm.
  ///
  /// Le RSSI etant bruite, l'entree se fait au rayon exact et la sortie
  /// un peu plus loin (hysteresis de 25 % : on ne sort pas pour un creux) :
  /// - entree a [rayonM] metres ;
  /// - sortie a `rayonM * 1.25` metres.
  ///
  /// La conversion RSSI <-> distance est l'inverse de [distanceEstimee]
  /// (reference -59 dBm a 1 m). C'est une approximation d'ordre de grandeur :
  /// elle sert a *decider* dans une zone, pas a mesurer au centimetre.
  factory ControleurProximite.rayon({
    required double rayonM,
    int mesuresPourDecider = 3,
    int dbmAUnMetre = -59,
  }) {
    final int entree = _dbmPourDistance(rayonM, dbmAUnMetre);
    final int sortie = _dbmPourDistance(rayonM * 1.25, dbmAUnMetre);
    return ControleurProximite(
      seuilEntreeDbm: entree,
      seuilSortieDbm: sortie,
      mesuresPourDecider: mesuresPourDecider,
    );
  }

  /// Conversion distance (m) -> RSSI (dBm), inverse de [distanceEstimee].
  ///
  /// Modele log-distance simplifie : `rssi = ref - 10 * n * log10(d)`, avec
  /// `n = 2.5` (interieur ouvert, comme [distanceEstimee]).
  static int _dbmPourDistance(double metres, int dbmAUnMetre) {
    if (metres <= 1) return dbmAUnMetre;
    final double dbm = dbmAUnMetre - 10 * 2.5 * (math.log(metres) / math.ln10);
    return dbm.round();
  }

  /// Seuil d'autorisation a l'entree (signal plus fort que ce niveau).
  final int seuilEntreeDbm;

  /// Seuil de deconnexion (signal plus faible que ce niveau).
  final int seuilSortieDbm;

  /// Nombre de mesures consecutives requises pour changer d'etat (lissage
  /// des creux/pics momentanes du RSSI).
  final int mesuresPourDecider;

  final Map<String, bool> _dedans = <String, bool>{};
  final Map<String, List<int>> _historique = <String, List<int>>{};

  /// Derniere mesure RSSI connue d'un appareil, pour l'UI de supervision.
  final Map<String, int> dernierRssi = <String, int>{};

  /// Etat courant : l'appareil est-il considere dans la zone ?
  bool estDedans(String device) => _dedans[device] ?? false;

  /// Estimation de distance pour l'affichage (CDC §21). Grossiere : le RSSI
  /// depend de l'antenne et des obstacles, la valeur sert a l'operateur, pas
  /// a un calcul.
  static int? distanceEstimee(int rssi) {
    // Reference a -59 dBm = ~1 m, facteur 2.5 typique en interieur ouvert.
    if (rssi >= 0) return null;
    final double d = (rssi + 59).abs() / (10 * 2.5);
    return d.round().clamp(1, 100);
  }

  /// Ingeste une mesure RSSI et retourne le verdict.
  ///
  /// [premiereMesureAutorisee] : au premier contact, un TAB 3 qui arrive deja
  /// proche doit pouvoir se connecter sans attendre l'historique complet.
  VerdictProximite evaluer(String device, int rssi) {
    dernierRssi[device] = rssi;
    final List<int> historique =
        (_historique[device] ??= <int>[])..add(rssi);
    if (historique.length > mesuresPourDecider) historique.removeAt(0);

    final bool dedans = _dedans[device] ?? false;

    // Decisions sur la moyenne des dernieres mesures : absorbe le bruit.
    final double moyenne =
        historique.reduce((a, b) => a + b) / historique.length;

    if (!dedans && historique.length == mesuresPourDecider &&
        moyenne >= seuilEntreeDbm) {
      _dedans[device] = true;
      historique.clear();
      return VerdictProximite.autorise;
    }
    // Sortie : meme regle de consecutive que l'entree (hysteresis symetrique).
    if (dedans && historique.length == mesuresPourDecider &&
        moyenne < seuilSortieDbm) {
      _dedans[device] = false;
      historique.clear();
      return VerdictProximite.refus;
    }
    // Dans la zone mais signal en baisse : a surveiller, sans decision.
    if (dedans && moyenne < seuilEntreeDbm) {
      return VerdictProximite.aSurveiller;
    }
    return dedans ? VerdictProximite.autorise : VerdictProximite.refus;
  }

  /// Premier contact d'un lien GATT deja etabli (CDC §8, étape « Contrôle de
  /// proximite » au moment du handshake).
  ///
  /// Contrairement au scan publicitaire, un lien GATT accepte est une preuve
  /// forte de proximité : une seule mesure au-dessus du seuil d'entrée suffit
  /// a autoriser, sinon on refuse et l'hysteresis du scan prendra le relais
  /// pour les tentatives suivantes.
  VerdictProximite evaluerPremierContact(String device, int rssi) {
    dernierRssi[device] = rssi;
    if (rssi >= seuilEntreeDbm) {
      _dedans[device] = true;
      _historique[device] = <int>[];
      return VerdictProximite.autorise;
    }
    _dedans[device] = false;
    return VerdictProximite.refus;
  }

  /// Oublie un appareil deconnecte (libere l'historique).
  void oublier(String device) {
    _dedans.remove(device);
    _historique.remove(device);
    dernierRssi.remove(device);
  }
}

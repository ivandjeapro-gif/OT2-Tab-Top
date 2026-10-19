import 'dart:convert';
import 'dart:typed_data';

/// Protocole applicatif Wi-Fi entre TAB 1 et TAB 2 (CDC §6, §7, §12).
///
/// TAB 2 sert de point d'accès Wi-Fi (REQ-007) et TAB 1 s'y associe ; TAB 2
/// collecte les données du spotter (REQ-008 : transfert rapide, portée 40 m,
/// reconnexion automatique). Le transport TCP délimite les messages par une
/// trame longueur + charge UTF-8 JSON — contrairement au BLE, le canal n'a
/// pas de borne de MTU : les trames longues passent, on borne quand même
/// pour rejeter les flux aberrants.
///
/// Types de messages (mêmes enveloppes §12 que le BLE) :
/// - `HANDSHAKE` / `HANDSHAKE_OK` / `HANDSHAKE_KO` — identification (REQ-017) ;
/// - `EVENEMENT` — lot de données métier du spotter (blast, lignes, blocs) ;
/// - `ACK` / `NACK` — accusé de réception, idempotence par event_id (§17) ;
/// - `PING` / `PONG` — battement de coeur pour la reconnexion auto (REQ-008).
class WifiProtocole {
  WifiProtocole._();

  /// Version du protocole (CDC §23).
  static const String version = '1.0';

  static const String typeHandshake = 'HANDSHAKE';
  static const String typeHandshakeOk = 'HANDSHAKE_OK';
  static const String typeHandshakeKo = 'HANDSHAKE_KO';
  static const String typeEvenement = 'EVENEMENT';
  static const String typeNotification = 'NOTIFICATION';
  static const String typeAck = 'ACK';
  static const String typeNack = 'NACK';
  static const String typePing = 'PING';
  static const String typePong = 'PONG';

  /// Garde-fou : au-delà, la trame est refusée (flux aberrant).
  static const int octetsMax = 1 << 20;

  /// Encode un message applicatif en trame Wi-Fi (longueur + JSON UTF-8).
  static Uint8List encoder(Map<String, Object?> message) =>
      TrameWifi.encadrer(utf8.encode(jsonEncode(message)));

  /// Décode une charge de trame en message applicatif. Null si illisible.
  static Map<String, Object?>? decoder(Uint8List octets) {
    try {
      final Object? decode = jsonDecode(utf8.decode(octets));
      if (decode is Map<String, Object?>) return decode;
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Enveloppe d'événement métier (CDC §12), identique au BLE.
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

  static Map<String, Object?> handshake({
    required String sourceDevice,
    required String role,
  }) =>
      <String, Object?>{
        'type': typeHandshake,
        'protocole': version,
        'source_device': sourceDevice,
        'role': role,
      };

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

  static Map<String, Object?> ack({required String eventId}) =>
      <String, Object?>{'type': typeAck, 'event_id': eventId};

  /// Notification serveur transmise sur le lien (Boss -> DT -> spotter),
  /// meme structure que la descente HTTP du canal notifications.
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

  static Map<String, Object?> nack({
    required String eventId,
    required String motif,
  }) =>
      <String, Object?>{
        'type': typeNack,
        'event_id': eventId,
        'motif': motif,
      };

  static Map<String, Object?> ping(String source) =>
      <String, Object?>{
        'type': typePing,
        'source': source,
        'timestamp': DateTime.now().toUtc().toIso8601String(),
      };

  static Map<String, Object?> pong(String source) =>
      <String, Object?>{
        'type': typePong,
        'source': source,
        'timestamp': DateTime.now().toUtc().toIso8601String(),
      };
}

/// Réfracteur de flux TCP : sur un canal continu, deux JSON dos à dos sont
/// indissociables. Chaque trame est précédée de sa longueur sur 4 octets
/// (big-endian), ce qui rend le flux insécable et résistant aux découpages
/// du noyau réseau (un JSON peut arriver en deux morceaux de socket).
class TrameWifi {
  TrameWifi._();

  /// Préfixe la charge de 4 octets de longueur big-endian.
  static Uint8List encadrer(List<int> charge) {
    final ByteData donnees = ByteData(4 + charge.length)
      ..setUint32(0, charge.length, Endian.big);
    donnees.buffer.asUint8List().setRange(4, 4 + charge.length, charge);
    return donnees.buffer.asUint8List();
  }

  /// Déframeur incrémental : on pousse les octets de socket tels qu'ils
  /// arrivent, il rend chaque trame complète reçue.
  static Deframeur demarreur() => Deframeur();
}

class Deframeur {
  final List<int> _tampon = <int>[];

  /// Pousse des octets de socket et rend les trames complètes qui en sortent.
  List<Uint8List> pousser(Uint8List octets) {
    final List<Uint8List> trames = <Uint8List>[];
    _tampon.addAll(octets);
    while (_tampon.length >= 4) {
      final int longueur = (_tampon[0] << 24) |
          (_tampon[1] << 16) |
          (_tampon[2] << 8) |
          _tampon[3];
      if (longueur > WifiProtocole.octetsMax) {
        // Flux aberrant : on purge, le pair se resynchronisera à la
        // reconnexion (REQ-008) — mieux que de bouffer la mémoire.
        _tampon.clear();
        return trames;
      }
      if (_tampon.length < 4 + longueur) break;
      trames.add(Uint8List.fromList(_tampon.sublist(4, 4 + longueur)));
      _tampon.removeRange(0, 4 + longueur);
    }
    return trames;
  }
}

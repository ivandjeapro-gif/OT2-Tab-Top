import 'dart:async';
import 'dart:typed_data';

/// Transport Wi-Fi abstrait entre TAB 1 et TAB 2 (CDC §6, REQ-007/008, §29).
///
/// TAB 2 héberge le point d'accès (role AP), TAB 1 s'y connecte (role STA).
/// Comme pour le BLE (§29 : matériel cible non encore validé), toute la logique
/// métier est codée contre cette interface : le banc en mémoire sert aux tests,
/// la vraie pile réseau (TCP sockets / `NetworkInterface`) s'y branchera sans
/// toucher au code au-dessus.
abstract class TransportWifi {
  /// Vrai tant que la radio Wi-Fi du device fonctionne.
  Stream<bool> get etatRadio;

  /// Cote client : liste les points d'accès ORE TRACKING à portée.
  Stream<ReseauWifi> scanner();

  /// Cote client : se connecte au point d'accès choisi.
  Future<LienWifi> connecter(ReseauWifi reseau);

  /// Cote gateway : écoute les connexions entrantes des TAB 1.
  Stream<LienWifi> liensEntrants() =>
      throw UnsupportedError('ce transport ne sert que de client');

  /// Arrête tout (scan, liens, serveur d'écoute).
  Future<void> arreter();
}

/// Un réseau Wi-Fi visible pendant le scan (le point d'accès de TAB 2).
class ReseauWifi {
  const ReseauWifi({
    required this.ssid,
    required this.adresse,
    this.puissance,
  });

  /// SSID annoncé par TAB 2 (ex. `ORE-TAB2-001`, CDC §19).
  final String ssid;

  /// Adresse IP du point d'accès.
  final String adresse;

  /// Puissance du signal en dBm (null si inconnu) — équivalent Wi-Fi du RSSI.
  final int? puissance;
}

/// Un lien TCP établi avec un pair.
abstract class LienWifi {
  /// Identifiant du pair distant (adresse IP ou id applicatif).
  String get idPair;

  /// Vrai tant que la socket est ouverte.
  bool get ouvert;

  /// Octets applicatifs reçus du pair (déjà reframés, voir [TrameWifi]).
  Stream<Uint8List> get messages;

  /// Envoie des octets applicatifs au pair. Lève si le lien est fermé.
  Future<void> envoyer(Uint8List octets);

  /// Ferme le lien (les deux côtés).
  Future<void> fermer();
}

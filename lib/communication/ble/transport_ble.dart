import 'dart:async';
import 'dart:typed_data';

/// Transport BLE abstrait (CDC §19 : la couche Communication doit pouvoir
/// evoluer sans dupliquer le code, et §29 : le materiel cible n'est pas encore
/// valide). Toute la logique metier (gateway, client) est codee contre cette
/// interface : les tests et le simulateur l'implémentent en memoire, la vraie
/// pile bluetooth arrive plus tard derriere la meme interface.
abstract class TransportBle {
  /// Vrai tant que la pile bluetooth du device fonctionne.
  Stream<bool> get etatPile;

  /// Scanne les appareils qui annoncent le service ORE TRACKING.
  /// Chaque emission est un appareil visible avec son RSSI courant.
  Stream<AppareilBle> scanner();

  /// Cote client : se connecte a un appareil. Cote gateway, la fonction
  /// n'est pas utilisee (le gateway accepte les connexions entrantes).
  Future<LienBle> connecter(AppareilBle appareil);

  /// Cote gateway : ecoute les connexions entrantes. Cote client, non
  /// utilise (le client initie toujours la connexion).
  Stream<LienBle> liensEntrants() =>
      throw UnsupportedError('ce transport ne sert que de client');

  /// Arrete tout (scan, liens, subscriptions).
  Future<void> arreter();
}

/// Un appareil BLE visible pendant le scan.
class AppareilBle {
  const AppareilBle({required this.id, required this.nom, this.rssi});

  final String id;
  final String nom;

  /// Dernier RSSI mesure pendant le scan (null si inconnu).
  final int? rssi;
}

/// Un lien GATT etabli avec un pair, apres negociation MTU.
abstract class LienBle {
  /// Identifiant du pair distant.
  String get idPair;

  /// Vrai tant que le lien GATT est ouvert.
  bool get ouvert;

  /// Messages applicatifs recus du pair.
  Stream<Uint8List> get messages;

  /// RSSI du lien, mesure a la demande (CDC §8).
  Future<int?> mesurerRssi();

  /// Envoie un message applicatif au pair. Leve si le lien est ferme.
  Future<void> envoyer(Uint8List octets);

  /// Ferme le lien (les deux cotes).
  Future<void> fermer();
}

/// Cote gateway : ecoute les connexions entrantes des TAB 3.
/// flutter_reactive_ble ne fournit pas de role peripherique nativement :
/// l'implementation reelle passera par un plugin complementaire
/// (flutter_ble_peripheral) — la signature reste la meme.
abstract class EcouteGateway {}

/// Lien dont le RSSI est declare par le pair plutot que mesure localement
/// (peripherique Android : le RSSI du lien GATT n'est pas lisible cote
/// server, le client le declare dans son handshake — CDC §8).
abstract class LienDeclaratif {
  int? rssiDeclare;
}

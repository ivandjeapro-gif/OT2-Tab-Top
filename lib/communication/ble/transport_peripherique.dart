import 'dart:async';
import 'dart:typed_data';

import 'package:ble_peripheral/ble_peripheral.dart' as periph;

import 'transport_ble.dart';

/// Transport BLE réel côté TAB 2 (peripherique / GATT server).
///
/// `flutter_reactive_ble` n'opère qu'en central : le role peripherique vient
/// du plugin `ble_peripheral` ([periph.BlePeripheral]), derriere la meme
/// interface [TransportBle] que le banc — la logique du gateway n'y change
/// rien (CDC §29).
///
/// Architecture GATT :
/// - un service ORE TRACKING primaire ;
/// - une caracteristique RX (le TAB 3 y ecrit ses messages) ;
/// - une caracteristique TX (TAB 2 notifie ses reponses : ACK, HANDSHAKE_*).
///
/// Limites connues du role peripherique :
/// - le RSSI natif n'est pas expose par Android sur un lien GATT server :
  /// le client mesure et declare son RSSI dans le handshake (champ `rssi`),
  /// que [LienPeripherique.mesurerRssi] renvoie en priorite ;
/// - l'identification du client (idPair) est l'adresse MAC fournie par la
///   pile Android, que le handshake complete par l'id applicatif.
class TransportBlePeripherique implements TransportBle {
  TransportBlePeripherique({
    // Inversion des roles (Voie 1) : c'est l'EXCAVATRICE qui emet, les DT
    // s'y accrochent. Le nom annonce distingue donc l'emetteur.
    this.nomPublic = 'ORE-EXC-001',
    this.serviceUuid = uuidService,
    this.caracteristiqueRx = uuidCaracteristiqueRx,
    this.caracteristiqueTx = uuidCaracteristiqueTx,
  });

  /// UUID du service ORE TRACKING (arbitraire mais fixe : les deux côtés
  /// doivent convenir des mêmes).
  static const String uuidService =
      '0000fe5a-0000-1000-8000-00805f9b34fb';
  static const String uuidCaracteristiqueRx =
      '0000fe5b-0000-1000-8000-00805f9b34fb';
  static const String uuidCaracteristiqueTx =
      '0000fe5c-0000-1000-8000-00805f9b34fb';

  /// Nom annoncé en advertising : les clients BLE (DT) cherchent un nom qui
  /// commence par `ORE-EXC` (BleClient.connecter).
  final String nomPublic;
  final String serviceUuid;
  final String caracteristiqueRx;
  final String caracteristiqueTx;

  final StreamController<LienBle> _entrants =
      StreamController<LienBle>.broadcast();
  final Map<String, LienPeripherique> _liens =
      <String, LienPeripherique>{};
  bool _prete = false;

  @override
  Stream<bool> get etatPile async* {
    yield true;
  }

  /// Prépare le GATT server : service + caractéristiques, callbacks. A
  /// appeler une fois avant [demarrerPublicite].
  Future<void> preparer() async {
    if (_prete) return;
    await periph.BlePeripheral.initialize();
    periph.BlePeripheral.setServiceAddedCallback(
        (String serviceId, String? erreur) {
      if (erreur != null) {
        throw StateError('Service GATT refuse : $erreur');
      }
    });
    await periph.BlePeripheral.addService(
      periph.BleService(
        uuid: serviceUuid,
        primary: true,
        characteristics: <periph.BleCharacteristic>[
          // RX : le client écrit ici (write sans réponse, pour ne pas
          // bloquer sur l'attente d'un accusé GATT).
          periph.BleCharacteristic(
            uuid: caracteristiqueRx,
            properties: <int>[
              periph.CharacteristicProperties.writeWithoutResponse.index,
              periph.CharacteristicProperties.write.index,
            ],
            permissions: <int>[
              periph.AttributePermissions.writeable.index,
            ],
          ),
          // TX : TAB 2 notifie ici (ACK, verdicts de handshake).
          periph.BleCharacteristic(
            uuid: caracteristiqueTx,
            properties: <int>[
              periph.CharacteristicProperties.read.index,
              periph.CharacteristicProperties.notify.index,
            ],
            permissions: <int>[
              periph.AttributePermissions.readable.index,
            ],
          ),
        ],
      ),
    );
    periph.BlePeripheral.setWriteRequestCallback(
      (
        String deviceId,
        String characteristicId,
        int offset,
        Uint8List? valeur,
      ) {
        if (characteristicId != caracteristiqueRx || valeur == null) {
          return null;
        }
        _livrer(deviceId, valeur);
        // Accusé GATT : écriture acceptée.
        return periph.WriteRequestResult(status: 0);
      },
    );
    periph.BlePeripheral.setConnectionStateChangeCallback(
      (String deviceId, bool connecte) {
        if (!connecte) _fermerLien(deviceId);
      },
    );
    _prete = true;
  }

  /// Démarre l'advertising : c'est ce qui rend TAB 2 visible des TAB 3.
  Future<void> demarrerPublicite() async {
    await preparer();
    await periph.BlePeripheral.startAdvertising(
      services: <String>[serviceUuid],
      localName: nomPublic,
    );
  }

  Future<void> arreterPublicite() =>
      periph.BlePeripheral.stopAdvertising();

  void _livrer(String deviceId, Uint8List octets) {
    // Un message du client crée le lien s'il n'existe pas encore : le
    // gateway s'abonne à `liensEntrants()` et déroule son handshake dessus.
    final LienPeripherique lien = _liens.putIfAbsent(
      deviceId,
      () {
        final LienPeripherique l = LienPeripherique._(
          this,
          deviceId,
        );
        _entrants.add(l);
        return l;
      },
    );
    lien._recevoir(octets);
  }

  void _fermerLien(String deviceId) {
    _liens.remove(deviceId)?._fermer();
  }

  Future<void> _notifier(LienPeripherique lien, Uint8List octets) =>
      periph.BlePeripheral.updateCharacteristic(
        characteristicId: caracteristiqueTx,
        value: octets,
        deviceId: lien.idPair,
      );

  // Non utilisé côté gateway : TAB 2 n'initie pas de connexion ni de scan.
  @override
  Stream<AppareilBle> scanner() =>
      throw UnsupportedError('le peripherique ne scanne pas');

  @override
  Future<LienBle> connecter(AppareilBle appareil) async =>
      throw UnsupportedError("le peripherique n'initie pas de connexion");

  @override
  Stream<LienBle> liensEntrants() => _entrants.stream;

  @override
  Future<void> arreter() async {
    await arreterPublicite();
    for (final String id in List<String>.of(_liens.keys)) {
      _fermerLien(id);
    }
    await _entrants.close();
  }
}

/// Lien GATT côté TAB 2, vu par le gateway comme un [LienBle] ordinaire.
class LienPeripherique implements LienBle, LienDeclaratif {
  LienPeripherique._(this._transport, this._deviceId);

  final TransportBlePeripherique _transport;
  final String _deviceId;
  final StreamController<Uint8List> _reception =
      StreamController<Uint8List>.broadcast();
  bool _ouvert = true;

  /// RSSI déclaré par le client dans son handshake (null tant qu'il n'a pas
  /// parlé) : Android ne l'expose pas côté peripherique.
  @override
  int? rssiDeclare;

  @override
  String get idPair => _deviceId;

  @override
  bool get ouvert => _ouvert;

  @override
  Stream<Uint8List> get messages => _reception.stream;

  @override
  Future<int?> mesurerRssi() async => rssiDeclare;

  @override
  Future<void> envoyer(Uint8List octets) async {
    if (!_ouvert) throw StateError('lien ferme');
    await _transport._notifier(this, octets);
  }

  @override
  Future<void> fermer() async => _fermer();

  void _fermer() {
    if (!_ouvert) return;
    _ouvert = false;
    _reception.close();
  }

  void _recevoir(Uint8List octets) {
    if (!_ouvert) return;
    _reception.add(octets);
  }
}

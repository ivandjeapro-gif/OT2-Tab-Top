import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_reactive_ble/flutter_reactive_ble.dart' as rble;

import 'transport_ble.dart';
import 'transport_peripherique.dart';

/// Transport BLE réel côté TAB 3 (central) : `flutter_reactive_ble`.
///
/// Implémente [TransportBle] : scan (discovery du service ORE TRACKING),
/// connexion GATT, envois par écriture de caractéristique, réception par
/// notifications. La logique du [BleClient] au-dessus ne change pas.
class TransportBleCentral implements TransportBle {
  TransportBleCentral({
    this.serviceUuid = TransportBlePeripherique.uuidService,
    this.caracteristiqueRx = TransportBlePeripherique.uuidCaracteristiqueRx,
    this.caracteristiqueTx = TransportBlePeripherique.uuidCaracteristiqueTx,
    rble.FlutterReactiveBle? pile,
  }) : _pile = pile ?? rble.FlutterReactiveBle();

  final String serviceUuid;
  final String caracteristiqueRx;
  final String caracteristiqueTx;

  final rble.FlutterReactiveBle _pile;
  final List<StreamSubscription<Object?>> _subs =
      <StreamSubscription<Object?>>[];

  @override
  Stream<bool> get etatPile => _pile.statusStream
      .map((rble.BleStatus s) => s == rble.BleStatus.ready)
      .asBroadcastStream();

  @override
  Stream<AppareilBle> scanner() async* {
    // `scanForDevices` émet un `DiscoveredDevice` par appareil vu, avec le
    // RSSI courant : exactement la forme [AppareilBle] attendue.
    await for (final rble.DiscoveredDevice d in _pile.scanForDevices(
      withServices: <rble.Uuid>[rble.Uuid.parse(serviceUuid)],
    )) {
      yield AppareilBle(id: d.id, nom: d.name, rssi: d.rssi);
    }
  }

  @override
  Future<LienBle> connecter(AppareilBle appareil) async {
    // La souscription maintient la connexion : tant qu'elle vit, le lien vit.
    final Completer<void> pret = Completer<void>();
    late final StreamSubscription<rble.ConnectionStateUpdate> sub;
    sub = _pile
        .connectToDevice(
          id: appareil.id,
          connectionTimeout: const Duration(seconds: 10),
        )
        .listen(
          (rble.ConnectionStateUpdate u) {
            if (u.connectionState == rble.DeviceConnectionState.connected &&
                !pret.isCompleted) {
              pret.complete();
            } else if (u.connectionState ==
                    rble.DeviceConnectionState.disconnected &&
                !pret.isCompleted) {
              pret.completeError(StateError('connexion BLE perdue'));
            }
          },
          onError: (Object e) {
            if (!pret.isCompleted) pret.completeError(e);
          },
        );
    _subs.add(sub);
    await pret.future;

    // MTU maximal : les messages JSON §12 doivent passer en une écriture.
    try {
      await _pile.requestMtu(deviceId: appareil.id, mtu: 512);
    } catch (_) {
      // Refus possible : les messages restent bornés par BleProtocole.
    }

    return LienCentral._(this, appareil.id);
  }

  @override
  Stream<LienBle> liensEntrants() =>
      throw UnsupportedError('le central ne sert que de client');

  @override
  Future<void> arreter() async {
    for (final StreamSubscription<Object?> s in List.of(_subs)) {
      await s.cancel();
    }
    _subs.clear();
  }
}

/// Lien GATT côté TAB 3 (central), vu par le BleClient comme un [LienBle].
class LienCentral implements LienBle {
  LienCentral._(this._transport, this._deviceId) {
    // Notifications de la caractéristique TX du peripherique (TAB 2).
    _subMessages = _transport._pile
        .subscribeToCharacteristic(
          rble.QualifiedCharacteristic(
            characteristicId: rble.Uuid.parse(_transport.caracteristiqueTx),
            serviceId: rble.Uuid.parse(_transport.serviceUuid),
            deviceId: _deviceId,
          ),
        )
        .listen(
          (List<int> octets) => _reception.add(Uint8List.fromList(octets)),
          onError: (Object _) => _fermer(),
          onDone: _fermer,
        );
  }

  final TransportBleCentral _transport;
  final String _deviceId;
  late final StreamSubscription<List<int>> _subMessages;
  final StreamController<Uint8List> _reception =
      StreamController<Uint8List>.broadcast();
  bool _ouvert = true;

  /// RSSI mesuré sur le lien central : le peripherique Android ne peut pas
  /// le lire, le client le déclare donc dans son handshake (CDC §8).
  int? rssiMesure;

  @override
  String get idPair => _deviceId;

  @override
  bool get ouvert => _ouvert;

  @override
  Stream<Uint8List> get messages => _reception.stream;

  /// Mesure le RSSI du lien (API centrale de la pile).
  @override
  Future<int?> mesurerRssi() async {
    try {
      rssiMesure = await _transport._pile.readRssi(_deviceId);
      return rssiMesure;
    } catch (_) {
      return rssiMesure;
    }
  }

  @override
  Future<void> envoyer(Uint8List octets) async {
    if (!_ouvert) throw StateError('lien ferme');
    await _transport._pile.writeCharacteristicWithoutResponse(
      rble.QualifiedCharacteristic(
        characteristicId: rble.Uuid.parse(_transport.caracteristiqueRx),
        serviceId: rble.Uuid.parse(_transport.serviceUuid),
        deviceId: _deviceId,
      ),
      value: octets,
    );
  }

  @override
  Future<void> fermer() async => _fermer();

  void _fermer() {
    if (!_ouvert) return;
    _ouvert = false;
    _reception.close();
    _subMessages.cancel();
  }
}

import 'dart:async';
import 'dart:typed_data';

import 'package:usb_serial/usb_serial.dart';

/// Port serie USB (XBee + GNSS u-blox sur un seul cable USB-C).
///
/// Le kit ArduSimple met sur le MÊME port USB un module XBee 3 (115200 bauds)
/// et un recepteur GNSS u-blox : on ne cherche PAS deux devices. On ouvre le
/// premier port disponible, et le filtrage binaire/texte se fait en amont :
///   - NMEA (texte `$Gx...`) et JSON tracking XBee -> parseur amont ;
///   - RTCM3 (binaire 0xD3...) -> remonte brut pour injection RTK.
///
/// Le nom de device contient generiquement « XBee » ou « u-blox » selon ce
/// que le fabricant a cense : on accepte tout device serie expose par
/// UsbManager — un seul s'ouvre de toute facon, il porte les deux flux.
class PortSerie {
  PortSerie();

  UsbPort? _port;
  StreamSubscription<Uint8List>? _sub;
  final StreamController<Uint8List> _octets =
      StreamController<Uint8List>.broadcast();
  bool _ouvert = false;
  UsbDevice? _device;

  /// Octets recus du port, dans l'ordre d'arrivee.
  Stream<Uint8List> get octets => _octets.stream;

  /// Vrai si le port est ouvert et lisible.
  bool get ouvert => _ouvert;

  /// Nom du device attaché (diagnostic UI). Vide si rien n'est branche.
  String get nomDevice => _device?.productName ?? '';

  /// Liste les devices USB visibles sans les ouvrir (diagnostic UI).
  static Future<List<UsbDevice>> lister() => UsbSerial.listDevices();

  /// Ouvre le premier port serie USB disponible.
  ///
  /// [baudRate] par defaut a 115200 (config XBee/u-blox du kit ArduSimple),
  /// mais modifiable depuis l'app (Parametres > XBee > `xbee_baudrate`) : les
  /// deux peripheriques partagent le MÊME port, la vitesse doit rester celle
  /// configuree dans u-center/XCTU.
  ///
  /// Rend false si aucun device, si l'utilisateur refuse la permission USB
  /// (dialogue systeme), ou si l'ouverture echoue (cable, droits host).
  Future<bool> ouvrir({int baudRate = 115200}) async {
    if (_ouvert) return true;
    final List<UsbDevice> devices = await UsbSerial.listDevices();
    if (devices.isEmpty) {
      return false;
    }
    // Le kit ArduSimple n'expose qu'un port composite ; on prend le premier.
    final UsbDevice device = devices.first;
    _device = device;
    // La permission n'est pas requise sur Android >= 12 (MISE EN PLACE par
    // l'APK cible) mais reste possible sur les versions anciennes : on tente
    // l'ouverture directe — create() reussit meme sans permission si le
    // device est deja autorise, sinon l'app echoue silencieusement.
    final UsbPort? port = await device.create();
    if (port == null) {
      return false;
    }
    if (!await port.open()) {
      return false;
    }
    // XBee et u-blox partagent le port : 8N1 a la vitesse configuree.
    port.setPortParameters(
      baudRate,
      UsbPort.DATABITS_8,
      UsbPort.STOPBITS_1,
      UsbPort.PARITY_NONE,
    );
    port.inputStream!.listen(
      (Uint8List data) {
        if (!_octets.isClosed) _octets.add(data);
      },
      onError: (Object e) => fermer(),
      onDone: () => fermer(),
    );
    _port = port;
    _ouvert = true;
    return true;
  }

  /// Ecrit sur le port. Rend false si le port n'est pas ouvert.
  ///
  /// `usb_serial` rend `Future<void>` sur `write` : on suppose un succes des
  /// lors que l'appel ne lève pas d'exception (meme contrat que le transport
  /// BLE, dont l'ecriture est elle aussi fire-and-forget).
  Future<bool> ecrire(Uint8List octets) async {
    final UsbPort? p = _port;
    if (p == null || !_ouvert) return false;
    try {
      await p.write(octets);
      return true;
    } on Exception {
      return false;
    }
  }

  /// Ferme le port et arrete l'ecoute. Idempotent.
  Future<void> fermer() async {
    _sub?.cancel();
    _sub = null;
    await _port?.close();
    _port = null;
    _ouvert = false;
    if (!_octets.isClosed) _octets.close();
  }
}

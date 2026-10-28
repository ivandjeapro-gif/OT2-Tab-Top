import 'dart:async';
import 'dart:typed_data';

import 'transport_ble.dart';

/// Simulateur BLE en memoire : implemente [TransportBle] sans materiel.
///
/// Sert aux tests et au developpement (CDC §29 : le materiel cible n'est pas
/// encore valide, la logique doit etre testable au banc). Deux transports
/// relies par [BancBle] jouent exactement le dialogue gateway <-> client,
/// y compris les echecs : lien coupe, appareil inconnu, TAB 2 absent.
///
/// Usage :
/// ```dart
/// final banc = BancBle();
/// final gateway = BleGateway(transport: banc.coteGateway, ...);
/// final client  = BleClient(transport: banc.coteClient, ...);
/// banc.tab3Arrive(nom: 'TAB3-001');
/// ```
class BancBle {
  BancBle() {
    coteClient._banc = this;
  }

  final CoteGatewayBle coteGateway = CoteGatewayBle._();
  final CoteClientBle coteClient = CoteClientBle._();

  /// Fait "entrer dans la zone" : le client (DT) devient detectable par
  /// l'emetteur, et l'emetteur (excavatrice) devient detectable par le client
  /// (nom publicitaire ORE-EXC).
  void tab3Arrive({String nom = 'TAB2-DT', int rssi = -55}) {
    coteGateway._appareilVisible
        .add(AppareilBle(id: nom, nom: nom, rssi: rssi));
    // Ce que le client voit pendant son scan : l'emetteur (excavatrice).
    coteClient._gatewaysVisibles
      ..clear()
      ..add(const AppareilBle(id: 'EXC-001', nom: 'ORE-EXC-001'));
  }

  /// Dernier lien cree cote gateway (inspection de banc).
  LienSimule? get dernierLienGateway => coteGateway._dernierLien;

  /// Lien courant cote client (inspection de banc).
  LienSimule? get dernierLienClient => coteClient._lien;

  /// Fait "sortir" le client de la zone : plus detectable.
  void tab3Part() => coteGateway._appareilVisible.clear();

  /// L'excavatrice (emetteur) est hors de portee : le client ne la voit plus
  /// au scan. C'est l'etat qui doit declencher une nouvelle tentative.
  void excavatriceHorsPortee() => coteClient._gatewaysVisibles.clear();

  /// L'excavatrice revient : le client la redécouvre au scan suivant.
  void excavatriceDeRetour({String id = 'EXC-001', String nom = 'ORE-EXC-001'}) =>
      coteClient._gatewaysVisibles
        ..clear()
        ..add(AppareilBle(id: id, nom: nom));

  /// Coupe le lien GATT en cours (obstacle, eloignement brutal).
  void couperLien() {
    coteClient._lien?.simulerCoupure();
    coteGateway._dernierLien?.simulerCoupureCote();
  }
}

/// Transport vu par le gateway (TAB 2) dans le banc.
class CoteGatewayBle implements TransportBle, EcouteGateway {
  CoteGatewayBle._();

  final List<AppareilBle> _appareilVisible = <AppareilBle>[];
  LienSimule? _dernierLien;
  final StreamController<LienBle> _entrants =
      StreamController<LienBle>.broadcast();

  @override
  Stream<bool> get etatPile => Stream<bool>.value(true);

  @override
  Stream<AppareilBle> scanner() async* {
    for (final AppareilBle a in List<AppareilBle>.of(_appareilVisible)) {
      yield a;
    }
  }

  @override
  Future<LienBle> connecter(AppareilBle appareil) async =>
      throw UnsupportedError("le gateway n'initie pas de connexion");

  /// Appele par le banc quand le client se connecte : fait apparaitre le lien.
  LienSimule accepterLien(LienSimule coteClient) {
    final LienSimule coteGateway = LienSimule._pair(coteClient);
    // Le lien est bidirectionnel : la moitie client doit aussi connaitre
    // sa moitie opposee, sinon ses envois partent dans le vide.
    coteClient._pair = coteGateway;
    _dernierLien = coteGateway;
    _entrants.add(coteGateway);
    return coteGateway;
  }

  @override
  Stream<LienBle> liensEntrants() => _entrants.stream;

  @override
  Future<void> arreter() async {
    await _entrants.close();
  }
}

/// Transport vu par le client (TAB 3) dans le banc.
class CoteClientBle implements TransportBle {
  CoteClientBle._();

  late BancBle _banc;
  final List<AppareilBle> _gatewaysVisibles = <AppareilBle>[];
  LienSimule? _lien;

  @override
  Stream<bool> get etatPile => Stream<bool>.value(true);

  @override
  Stream<AppareilBle> scanner() async* {
    // Ce que le client voit : les gateways ORE-TAB2 a portee.
    for (final AppareilBle g in List<AppareilBle>.of(_gatewaysVisibles)) {
      yield g;
    }
  }

  @override
  Stream<LienBle> liensEntrants() =>
      throw UnsupportedError('ce transport ne sert que de client');

  /// Le client "se connecte" : le banc cree le lien des deux cotes.
  @override
  Future<LienBle> connecter(AppareilBle appareil) async {
    final LienSimule coteClient = LienSimule._();
    _lien = coteClient;
    _banc.coteGateway.accepterLien(coteClient);
    return coteClient;
  }

  @override
  Future<void> arreter() async {}
}

/// Lien GATT simule : deux moities qui se parlent immediatement.
class LienSimule implements LienBle {
  LienSimule._();
  LienSimule._pair(this._pair) : _ouvert = true;

  LienSimule? _pair;
  Stream<Uint8List>? _messages;
  bool _ouvert = true;
  final StreamController<Uint8List> _reception =
      StreamController<Uint8List>.broadcast();

  @override
  String get idPair => 'SIMULE';

  @override
  bool get ouvert => _ouvert;

  @override
  Stream<Uint8List> get messages => _messages ??= _reception.stream;

  /// Abonnes en cours (inspection de banc).
  int get abonnes => _reception.hasListener ? 1 : 0;

  /// Recepteurs ayant deja consomme un flux (inspection de banc).
  bool get recepteurs => _messages != null;

  /// RSSI fixe du banc, modifiable pour tester l'hysteresis.
  int rssiSimule = -55;

  @override
  Future<int?> mesurerRssi() async => _ouvert ? rssiSimule : null;

  @override
  Future<void> envoyer(Uint8List octets) async {
    if (!_ouvert) throw StateError('lien ferme');
    // Livraison asynchrone : imite le timing réel du BLE, où le message part
    // après le retour de writeCharacteristic, jamais au milieu de lui.
    scheduleMicrotask(() => _pair?._reception.add(octets));
  }

  @override
  Future<void> fermer() async {
    _ouvert = false;
    await _reception.close();
    _pair?._ouvert = false;
    _pair?._reception.close();
  }

  /// Coupe uniquement ce cote (obstacle asymetrique).
  void simulerCoupureCote() {
    _ouvert = false;
    _reception.close();
  }

  void simulerCoupure() {
    _ouvert = false;
    _reception.close();
  }
}

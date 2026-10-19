import 'dart:async';
import 'dart:typed_data';

import 'transport_wifi.dart';
import 'wifi_protocole.dart';

/// Simulateur Wi-Fi en mémoire : implémente [TransportWifi] sans matériel,
/// même esprit que [BancBle] (CDC §29). Deux transports reliés jouent le
/// dialogue point d'accès <-> client, y compris les pannes : coupure de lien,
/// appareil inconnu, TAB 2 absent, fragmentation TCP (un JSON qui arrive en
/// deux paquets doit être réassemblé par [TrameWifi]).
class BancWifi {
  BancWifi() {
    coteClient._banc = this;
  }

  final CoteGatewayWifi coteGateway = CoteGatewayWifi._();
  final CoteClientWifi coteClient = CoteClientWifi._();

  /// Fait "entrer dans la zone" : l'emetteur (excavatrice) devient visible.
  void tab2Present({String ssid = 'ORE-EXC-001'}) {
    coteClient._reseauxVisibles
      ..clear()
      ..add(ReseauWifi(ssid: ssid, adresse: '192.168.49.1', puissance: -40));
  }

  /// TAB 2 sort de portée (40 m dépassés, REQ-007).
  void tab2Absent() => coteClient._reseauxVisibles.clear();

  /// Coupe le lien TCP en cours (sortie de zone brutale).
  void couperLien() {
    coteClient._lien?.simulerCoupure();
    coteGateway._dernierLien?.simulerCoupureCote();
  }

  /// Livre la prochaine trame du client au gateway en deux paquets de
  /// socket : teste le réfracteur sans changer le code applicatif.
  void fragmenterProchainEnvoi(bool valeur) =>
      coteClient._lien?._fragmenterProchain = valeur;
}

/// Transport vu par le point d'accès (TAB 2) dans le banc.
class CoteGatewayWifi implements TransportWifi {
  CoteGatewayWifi._();

  final List<ReseauWifi> _reseauxVisibles = <ReseauWifi>[];
  LienSimuleWifi? _dernierLien;
  final StreamController<LienWifi> _entrants =
      StreamController<LienWifi>.broadcast();

  @override
  Stream<bool> get etatRadio => Stream<bool>.value(true);

  @override
  Stream<ReseauWifi> scanner() async* {
    for (final ReseauWifi r in List<ReseauWifi>.of(_reseauxVisibles)) {
      yield r;
    }
  }

  @override
  Future<LienWifi> connecter(ReseauWifi reseau) async =>
      throw UnsupportedError("le gateway n'initie pas de connexion");

  /// Appelé par le banc quand le client s'associe.
  LienSimuleWifi accepterLien(LienSimuleWifi coteClient) {
    final LienSimuleWifi coteGateway = LienSimuleWifi._pair(coteClient);
    coteClient._pair = coteGateway;
    _dernierLien = coteGateway;
    _entrants.add(coteGateway);
    return coteGateway;
  }

  @override
  Stream<LienWifi> liensEntrants() => _entrants.stream;

  @override
  Future<void> arreter() async {
    await _entrants.close();
  }
}

/// Transport vu par le client (TAB 1) dans le banc.
class CoteClientWifi implements TransportWifi {
  CoteClientWifi._();

  late BancWifi _banc;
  final List<ReseauWifi> _reseauxVisibles = <ReseauWifi>[];
  LienSimuleWifi? _lien;

  @override
  Stream<bool> get etatRadio => Stream<bool>.value(true);

  @override
  Stream<ReseauWifi> scanner() async* {
    for (final ReseauWifi r in List<ReseauWifi>.of(_reseauxVisibles)) {
      yield r;
    }
  }

  @override
  Stream<LienWifi> liensEntrants() =>
      throw UnsupportedError('ce transport ne sert que de client');

  /// Le client "s'associe" : le banc crée le lien des deux côtés.
  @override
  Future<LienWifi> connecter(ReseauWifi reseau) async {
    final LienSimuleWifi coteClient = LienSimuleWifi._();
    _lien = coteClient;
    _banc.coteGateway.accepterLien(coteClient);
    return coteClient;
  }

  @override
  Future<void> arreter() async {}
}

/// Lien TCP simulé : deux moitiés qui se parlent immédiatement.
class LienSimuleWifi implements LienWifi {
  LienSimuleWifi._();
  LienSimuleWifi._pair(this._pair) : _ouvert = true;

  LienSimuleWifi? _pair;
  bool _ouvert = true;
  bool _fragmenterProchain = false;
  final StreamController<Uint8List> _reception =
      StreamController<Uint8List>.broadcast();

  @override
  String get idPair => 'SIMULE';

  @override
  bool get ouvert => _ouvert;

  @override
  Stream<Uint8List> get messages => _reception.stream;

  @override
  Future<void> envoyer(Uint8List octets) async {
    if (!_ouvert) throw StateError('lien ferme');
    // Livraison en microtask, comme le banc BLE : imite le timing réseau réel
    // (le message part après le retour de socket, jamais au milieu de lui).
    // Comme sur un vrai lien TCP, on transporte la trame encadrée : le côté
    // opposé la passe au déframeur avant de l'exposer sur `messages`.
    if (_fragmenterProchain) {
      // Simule un découpage TCP : deux paquets, le JSON n'arrive entier que
      // après réassemblage par le déframeur du pair.
      final int coupe = octets.length < 3 ? 1 : octets.length ~/ 3;
      scheduleMicrotask(() {
        _pair?._recevoir(Uint8List.sublistView(octets, 0, coupe));
        _pair?._recevoir(Uint8List.sublistView(octets, coupe));
      });
      _fragmenterProchain = false;
      return;
    }
    scheduleMicrotask(() => _pair?._recevoir(octets));
  }

  /// Réception côté socket : déframe puis expose la charge applicative.
  void _recevoir(Uint8List trame) {
    if (!_ouvert) return;
    for (final Uint8List charge in _deframeur.pousser(trame)) {
      _reception.add(charge);
    }
  }

  final Deframeur _deframeur = TrameWifi.demarreur();

  @override
  Future<void> fermer() async {
    _ouvert = false;
    await _reception.close();
    _pair?._ouvert = false;
    _pair?._reception.close();
  }

  /// Coupe uniquement ce côté (obstacle asymétrique).
  void simulerCoupureCote() {
    _ouvert = false;
    _reception.close();
  }

  void simulerCoupure() {
    _ouvert = false;
    _reception.close();
  }
}

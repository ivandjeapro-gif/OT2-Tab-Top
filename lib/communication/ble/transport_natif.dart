import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import 'ble_machine_etat.dart';
import 'transport_ble.dart';

/// Transport BLE qui s'appuie sur le canal NATIF Android
/// (`BleCentralManager`, `connectGatt(autoConnect = true)`).
///
/// POURQUOI CETTE CLASSE PLUTOT QUE BRANCHER `BleClient` DIRECTEMENT SUR LA
/// MACHINE D'ETAT. `BleClient` est ecrit contre [TransportBle] : il demande un
/// scan, une connexion, et recoit un [LienBle]. En implementant cette meme
/// interface au-dessus de [BleMachineEtat], le client conserve TOUTE sa
/// logique metier — handshake, file d'attente, ACK, retransmission — sans une
/// ligne de changement. Seul le transport change : `flutter_reactive_ble`
/// laisse la place au GATT natif, qui seul sait faire `autoConnect`.
///
/// CE QUE CE TRANSPORT APPORTE :
///  - reconnexion automatique par le SYSTEME (aucun scan periodique) ;
///  - persistance de l'appairage (SharedPreferences) ;
///  - nettoyage GATT avant chaque tentative ;
///  - watchdog de 15 s sur le silence.
///
/// Hors Android, tout est no-op : l'application reste utilisable (tests,
/// desktop) et les bancs continuent d'injecter leurs transports simules.
class TransportBleNatif implements TransportBle {
  TransportBleNatif({BleMachineEtat? machine})
    : machine = machine ?? BleMachineEtat();

  /// Machine d'etat partagee : c'est elle qui porte l'etat courant, que la
  /// session lit pour ses voyants.
  final BleMachineEtat machine;

  final StreamController<LienBle> _entrants =
      StreamController<LienBle>.broadcast();
  final StreamController<bool> _etatPile = StreamController<bool>.broadcast();

  LienBleNatif? _lien;
  StreamSubscription<Uint8List>? _subOctets;
  StreamSubscription<void>? _subTrame;
  void Function()? _ecouteurMachine;
  bool _demarre = false;

  /// Vrai si la plateforme dispose du canal natif.
  ///
  /// `dart:io` n'existe pas sur le web : la constante est evaluee au chargement
  /// de la bibliotheque, et sur web ce fichier n'est de toute facon pas
  /// compile (aucun import conditionnel necessaire).
  static bool get disponible => Platform.isAndroid;

  @override
  Stream<bool> get etatPile async* {
    yield disponible;
    yield* _etatPile.stream;
  }

  /// Branche la machine : etats, octets recus, heartbeat.
  Future<void> demarrer() async {
    if (_demarre) return;
    _demarre = true;
    if (!disponible) return;

    // Machine -> transport : chaque trame recue est poussee dans le lien
    // courant, que `BleClient` ecoute comme n'importe quel autre lien.
    _subOctets = machine.octetsRecus.listen((Uint8List octets) {
      _lien?._livrer(octets);
    });
    // Etat de la pile : reflete la machine (connexion perdue / revenue).
    // `ChangeNotifier` previent a chaque transition ; il suffit de relayer
    // `disponible` a chaque fois, c'est le seul signal attendu par le client.
    void surChangement() {
      if (!_etatPile.isClosed) _etatPile.add(disponible);
    }

    machine.addListener(surChangement);
    _ecouteurMachine = surChangement;
    await machine.demarrer();
  }

  @override
  Stream<AppareilBle> scanner() async* {
    if (!disponible) return;
    // La machine gere le scan (filtre service + temporisation). On expose
    // simplement ce qu'elle a vu pendant sa derniere passe.
    await machine.demarrer();
    for (final AppareilVu vu in List<AppareilVu>.of(machine.appareilsVus)) {
      yield AppareilBle(
        id: vu.adresse,
        nom: vu.nom,
        rssi: vu.rssi,
        serviceOre: true,
      );
    }
  }

  @override
  Future<LienBle> connecter(AppareilBle appareil) async {
    if (!disponible) {
      throw UnsupportedError('canal BLE natif absent sur cette plateforme');
    }
    await machine.demarrer();

    // Le lien est rendu immediatement : sa disponibilite EST l'etat de la
    // machine. `BleClient` s'abonne ensuite a `messages` pour le handshake —
    // exactement comme avec le transport `flutter_reactive_ble`.
    final LienBleNatif lien = LienBleNatif._(this, appareil.id, appareil.nom);
    _lien = lien;
    _entrants.add(lien);
    unawaited(machine.memoriser(appareil.id, appareil.nom));
    return lien;
  }

  @override
  Stream<LienBle> liensEntrants() => _entrants.stream;

  /// Ecrit vers l'excavatrice via le canal natif.
  Future<bool> ecrire(Uint8List octets) => machine.envoyer(octets);

  void _fermerLien(LienBleNatif lien) {
    if (identical(_lien, lien)) _lien = null;
  }

  @override
  Future<void> arreter() async {
    _demarre = false;
    await _subOctets?.cancel();
    _subOctets = null;
    await _subTrame?.cancel();
    _subTrame = null;
    if (_ecouteurMachine != null) {
      machine.removeListener(_ecouteurMachine!);
      _ecouteurMachine = null;
    }
    await machine.arreter();
    machine.dispose();
    await _entrants.close();
    await _etatPile.close();
  }

}

/// Lien GATT natif vu par `BleClient` comme un [LienBle].
class LienBleNatif implements LienBle {
  LienBleNatif._(this._transport, this._id, this._nom);

  final TransportBleNatif _transport;
  final String _id;
  final String _nom;

  final StreamController<Uint8List> _reception =
      StreamController<Uint8List>.broadcast();
  bool _ouvert = true;

  @override
  String get idPair => _id;

  /// Nom annonce par l'excavatrice (peut etre vide : Android l'omet parfois).
  String get nomPair => _nom;

  @override
  bool get ouvert => _ouvert;

  @override
  Stream<Uint8List> get messages => _reception.stream;



  /// Livre les octets recus de la machine d'etat.
  void _livrer(Uint8List octets) {
    if (!_reception.isClosed) _reception.add(octets);
  }

  @override
  Future<void> envoyer(Uint8List octets) async {
    final bool ok = await _transport.ecrire(octets);
    if (!ok) throw StateError('ecriture BLE refusee');
  }

  @override
  Future<int?> mesurerRssi() async => null;

  @override
  Future<void> fermer() async {
    _ouvert = false;
    _transport._fermerLien(this);
    if (!_reception.isClosed) await _reception.close();
  }
}

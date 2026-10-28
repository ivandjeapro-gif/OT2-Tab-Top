import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'transport_wifi.dart';
import 'wifi_protocole.dart';

/// Transport Wi-Fi réel : sockets TCP (ServerSocket côté TAB 2, Socket côté
/// TAB 1). Implémente [TransportWifi] — la logique métier au-dessus ne change
/// pas d'un octet entre le banc et le terrain (CDC §29).
///
/// Hypothèse réseau : TAB 2 est le point d'accès (hotspot Android activé par
/// ailleurs, non géré ici) et connaît son IP ; TAB 1 s'est associé au réseau
/// et scanne les hôtes du sous-réseau pour trouver TAB 2 (le SSID annoncé ne
/// suffit pas à trouver l'adresse, le [scanner] teste le port applicatif).
class TransportTcpWifi implements TransportWifi {
  TransportTcpWifi({
    required this.port,
    this.adresseLocale = '0.0.0.0',
    this.delaiConnexion = const Duration(seconds: 3),
  });

  /// Port applicatif ORE TRACKING (fixe, les deux côtés le connaissent).
  final int port;

  /// Adresse d'écoute du gateway (toutes les interfaces par défaut).
  final String adresseLocale;

  /// Délai d'un test d'hôte pendant le scan.
  final Duration delaiConnexion;

  ServerSocket? _serveur;
  int _port = 0;
  final StreamController<LienWifi> _entrants =
      StreamController<LienWifi>.broadcast();
  final List<SocketLienWifi> _liens = <SocketLienWifi>[];

  /// Port réellement écouté après [heberger] (utile quand [port] vaut 0 : le
  /// système choisit un port libre, indispensable en CI pour éviter les
  /// collisions). 0 tant que le serveur n'est pas démarré.
  int get portEcoute => _port;

  @override
  Stream<bool> get etatRadio async* {
    yield true;
    // Une vraie détection de radio passerait par connectivity_plus ;
    // l'app coupera la couche par la session en cas de perte du réseau.
  }

  // ---------------------------------------------------------------- côté TAB 2

  /// Démarre le serveur d'écoute (point d'accès TAB 2).
  ///
  /// IMPORTANT : on ecoute sur `0.0.0.0` (toutes interfaces), jamais sur
  /// l'IP d'une interface precise. Sur Android, binder une adresse locale
  /// alors qu'un port deja ecoute sur une autre interface leve
  /// `SocketException: The shared flag to bind() needs to be 'true'` —
  /// c'etait le cas ici (server socket refuse, DT injoignable). Ecouter
  /// partout couvre aussi le hotspot ET le Wi-Fi local, ce qui est
  /// exactement le souhait d'une passerelle.
  Future<void> heberger() async {
    if (_serveur != null) return;
    try {
      _serveur = await ServerSocket.bind(
        InternetAddress.anyIPv4,
        port,
        shared: false,
      );
    } on SocketException {
      // Port deja pris (instance precedente non liberee) : on retente en
      // partage, ce qu'Android autorise explicitement a plusieurs sockets.
      _serveur = await ServerSocket.bind(
        InternetAddress.anyIPv4,
        port,
        shared: true,
      );
    }
    _port = _serveur!.port;
    _serveur!.listen(
      (Socket socket) {
        final SocketLienWifi lien = SocketLienWifi._client(socket);
        _liens.add(lien);
        _entrants.add(lien);
      },
      onError: (Object _) => _fermerServeur(),
      onDone: _fermerServeur,
    );
  }

  void _fermerServeur() {
    _serveur = null;
  }
  /// Adresse IP locale du device (celle de l'interface Wi-Fi en pratique) :
  /// TAB 1 la cherche sur le sous-réseau, TAB 2 peut l'afficher (§21).
  static Future<String?> trouverAdresseLocale() async {
    final List<NetworkInterface> interfaces =
        await NetworkInterface.list(type: InternetAddressType.IPv4);
    for (final NetworkInterface i in interfaces) {
      for (final InternetAddress a in i.addresses) {
        if (!a.isLoopback) return a.address;
      }
    }
    return null;
  }

  @override
  Stream<LienWifi> liensEntrants() => _entrants.stream;

  // ---------------------------------------------------------------- côté TAB 1

  /// Scanne le sous-réseau local à la recherche du point d'accès TAB 2
  /// (port applicatif ouvert). Émet chaque réseau trouvé.
  ///
  /// [sousReseau] : préfixe, ex. `192.168.49` (déduit de l'IP locale si omis).
  @override
  Stream<ReseauWifi> scanner() async* {
    final String? locale = await trouverAdresseLocale();
    final String prefixe = sousReseauDe(locale) ?? '192.168.49';
    // Scan borné : .1 est le candidat principal (le hotspot Android donne
    // souvent cette adresse à l'hôte), les suivants sont essayés en parallèle.
    const int maxHotes = 64;
    final List<Future<ReseauWifi?>> tests = <Future<ReseauWifi?>>[];
    for (int hote = 1; hote <= maxHotes; hote++) {
      tests.add(_testerHote('$prefixe.$hote'));
    }
    final List<ReseauWifi?> trouves = await Future.wait(tests);
    for (final ReseauWifi? r in trouves) {
      if (r != null) yield r;
    }
  }

  /// Déduit le préfixe du sous-réseau (a.b.c) d'une adresse a.b.c.d.
  static String? sousReseauDe(String? adresse) {
    if (adresse == null) return null;
    final RegExpMatch? m =
        RegExp(r'^(\d+\.\d+\.\d+)\.\d+$').firstMatch(adresse);
    return m?.group(1);
  }

  Future<ReseauWifi?> _testerHote(String hote) async {
    try {
      final Socket socket = await Socket.connect(hote, port,
              timeout: delaiConnexion)
          .timeout(delaiConnexion);
      // Hôte trouvé — on referme aussitôt : la vraie connexion est faite
      // par [connecter], le scan ne fait que découvrir.
      socket.destroy();
      return ReseauWifi(ssid: 'ORE-EXC', adresse: hote, puissance: 0);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<LienWifi> connecter(ReseauWifi reseau) async {
    // Lier la socket à l'interface du même sous-réseau que la cible : sans
    // cela, le trafic part sur la route par défaut (4G — le mécanisme
    // « forcer cellulaire » l'impose) et la connexion au serveur local
    // échouait alors que le réseau Wi-Fi était sain (observé 21/10 :
    // ping -I wlan0 → 0 % de perte, sans → 100 %).
    InternetAddress? source;
    try {
      final List<NetworkInterface> interfaces =
          await NetworkInterface.list(type: InternetAddressType.IPv4);
      final String prefixe = sousReseauDe(reseau.adresse) ?? '';
      for (final NetworkInterface i in interfaces) {
        for (final InternetAddress a in i.addresses) {
          if (!a.isLoopback && a.address.startsWith(prefixe)) {
            source = a;
            break;
          }
        }
        if (source != null) break;
      }
    } catch (_) {
      // Pas d'interface matchée : connexion sans liaison explicite.
    }
    final Socket socket = await Socket.connect(reseau.adresse, port,
            sourceAddress: source,
            timeout: delaiConnexion)
        .timeout(delaiConnexion);
    return SocketLienWifi._client(socket);
  }

  @override
  Future<void> arreter() async {
    _fermerServeur();
    for (final SocketLienWifi l in List<SocketLienWifi>.of(_liens)) {
      await l.fermer();
    }
    _liens.clear();
    await _entrants.close();
  }
}

/// Lien TCP réel : un socket de chaque côté.
class SocketLienWifi implements LienWifi {
  SocketLienWifi._client(this._socket) : _ouvert = true {
    // Sur une vraie socket, un message applicatif peut arriver en plusieurs
    // paquets TCP : tout passe par le déframeur, comme dans le banc.
    _socket.listen(
      _recevoir,
      onError: (Object _) => _fermer(),
      onDone: _fermer,
    );
  }

  final Socket _socket;
  final Deframeur _deframeur = TrameWifi.demarreur();
  bool _ouvert;
  final StreamController<Uint8List> _reception =
      StreamController<Uint8List>.broadcast();

  @override
  String get idPair => _socket.remoteAddress.address;

  @override
  bool get ouvert => _ouvert;

  @override
  Stream<Uint8List> get messages => _reception.stream;

  @override
  Future<void> envoyer(Uint8List octets) async {
    if (!_ouvert) throw StateError('lien ferme');
    _socket.add(octets);
  }

  void _recevoir(Uint8List paquets) {
    if (!_ouvert) return;
    for (final Uint8List charge in _deframeur.pousser(paquets)) {
      _reception.add(charge);
    }
  }

  void _fermer() {
    if (!_ouvert) return;
    _ouvert = false;
    _reception.close();
    _socket.destroy();
  }

  @override
  Future<void> fermer() async => _fermer();
}

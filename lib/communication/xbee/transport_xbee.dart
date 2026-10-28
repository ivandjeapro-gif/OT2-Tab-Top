import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../usb/port_serie.dart';
import '../gnss/parseur_nmea.dart';

/// Transport XBee 3 (USB-C, 115200 bauds) cote TABLETTE embarquee dans un DT.
///
/// Architecture radio :
///   - chaque DT porte un module XBee 3 (meme antenne baguette) ;
///   - UN SEUL module de base fixe, au depot, ecoute TOUT le parc — les
///     tablettes n'echangent JAMAIS entre elles par radio ;
///   - la base, connectee au serveur, pousse les donnees vers GAS.
///
/// La latence est courte (ce sont des datagrammes 802.15.4 directs, pas un
/// maillage), ce qui est OK pour du tracking. En revanche, ce canal ne sert
/// A RIEN pour la configuration du DT : elle passe par BLE/Wi-Fi.
///
/// Bilateralite :
///   - montee : le DT encapsule sa position en JSON signe et l'envoie a la
///     base ;
///   - descente : la base peut adresser un message a un DT specifique (par
///     son `id`), ou broadcaster (adresse `FFFF` en broadcast) — e.g. une
///     notification « nouvelle mission » quand le site est hors reseau.
///
/// API calque sur TransportBle : demarrer/arreter, recevoir, envoyer.
class TransportXbee {
  TransportXbee({PortSerie? portSerie, this.idEmetteur = ''})
    : _portSerie = portSerie ?? PortSerie();

  /// Identifiant JSON du DT (ex. `DT_1500-3`) — sert a signer les trames
  /// montantes et a filtrer les trames descendantes qui nous sont destinees.
  final String idEmetteur;

  final PortSerie _portSerie;
  final ParseurNmea _nmea = ParseurNmea();
  StreamSubscription<Uint8List>? _sub;
  final StreamController<String> _recus = StreamController<String>.broadcast();
  final StreamController<MesureGga> _gga =
      StreamController<MesureGga>.broadcast();
  bool _demarre = false;

  /// Tampon texte des trames JSON en cours d'assemblage.
  ///
  /// Un cadre peut arriver en plusieurs fragments du port serie (un octet
  /// par paquet est courant sur USB-HID d'Android). Sans ce tampon, le `{`
  /// d'ouverture tombait dans un fragment precedent et la trame entiere etait
  /// jetee en silence — la base pouvait emettre, le DT ne voyait rien.
  /// On ne garde que la fin du flux (une trame non fermee au-dela de
  /// [_tailleMaxTampon] est forcement du bruit : RTCM, trames coupees).
  String _tampon = '';
  static const int _tailleMaxTampon = 4096;

  /// Messages JSON recus de la base (ou d'un autre DT en broadcast).
  Stream<String> get messages => _recus.stream;

  /// Positions NMEA decodées du recepteur GNSS partageant le port USB.
  Stream<MesureGga> get positions => _gga.stream;

  /// Le port serie est-il ouvert ? (diagnostic UI : badge XBee)
  bool get pret => _demarre && _portSerie.ouvert;

  /// Nom du device USB attache (diagnostic UI).
  String get nomDevice => _portSerie.nomDevice;

  /// Demarre le transport : ouvre le port serie et ecoute.
  ///
  /// [baudRate] par defaut a 115200 (config u-center/XCTU du kit), modifiable
  /// depuis l'app (Parametres > XBee > `xbee_baudrate`) sans rebuild. La
  /// vitesse doit rester celle configuree dans u-center/XCTU : les deux bouts
  /// du port (GNSS et XBee) partagent le meme lien serie.
  ///
  /// Rend false si aucun device USB n'est branche, ou si l'utilisateur
  /// refuse la permission USB.
  Future<bool> demarrer({int baudRate = 115200}) async {
    if (_demarre) return true;
    final bool ok = await _portSerie.ouvrir(baudRate: baudRate);
    if (!ok) return false;
    _sub = _portSerie.octets.listen(_traiterOctets);
    _demarre = true;
    return true;
  }

  /// Traite un fragment d'octets du port USB : peut contenir une fin de
  /// phrase NMEA, un cadre XBee JSON (entre accolades), ou du RTCM binaire
  /// (ignore ici, remonte par la couche RTK).
  void _traiterOctets(Uint8List data) {
    // 1. NMEA : le parseur bufferise et rend les phrases completes.
    for (final String phrase in _nmea.ajouter(data)) {
      final MesureGga? m = ParseurNmea.decoderGga(phrase);
      if (m != null && !_gga.isClosed) {
        _gga.add(m);
      }
    }
    // 2. JSON XBee : les cadres de la base arrivent aussi sur ce port.
    //    Format attendu : `{"src":"BASE","dst":"DT_1500-3","payload":{...}}`
    //    Le texte est delimite par des accolades equilibrees ; on cherche
    //    une sous-chaine JSON valide dans le fragment.
    _tampon += utf8.decode(data, allowMalformed: true);
    if (_tampon.length > _tailleMaxTampon) {
      _tampon = _tampon.substring(_tampon.length - _tailleMaxTampon);
    }
    int depart = _tampon.indexOf('{');
    while (depart >= 0) {
      final int fin = _trouverFinJson(_tampon, depart);
      if (fin < 0) {
        // Trame incomplete : on jette ce qui precede le `{` et on GARDE le
        // debut en attente du prochain fragment. Un JSON valide ne contient
        // pas de `{` orphelin : s'il y en a un avant, c'est du bruit.
        _tampon = _tampon.substring(depart);
        return;
      }
      final String candidat = _tampon.substring(depart, fin + 1);
      depart = _tampon.indexOf('{', fin + 1);
      try {
        final Map<String, dynamic> j =
            jsonDecode(candidat) as Map<String, dynamic>;
        // Filtre de destination : la base adresse ce DT explicitement, ou
        // broadcast (dst vide / `*` / `ALL`). Les messages destines a un
        // autre DT sont ignores — jamais re-emit (pas de maillage).
        final String dst = (j['dst'] as String? ?? '').trim().toUpperCase();
        final String moi = idEmetteur.toUpperCase();
        final bool pourMoi =
            dst.isEmpty || dst == '*' || dst == 'ALL' || dst == moi;
        if (!pourMoi) continue;
        if (!_recus.isClosed) _recus.add(candidat);
      } on FormatException {
        // Fragment invalide ou RTCM binaire : on ignore silencieusement.
      }
    }
    // Plus de `{` en attente : tout ce qui reste ne peut pas ouvrir une trame.
    _tampon = '';
  }

  /// Rend l'index du `}` qui ferme le JSON ouvert a [depart], ou -1 si le
  /// JSON n'est pas encore complet dans le tampon. Le caller CONSERVE alors
  /// tout ce qui suit [depart] et rappellera cette methode au fragment
  /// suivant : c'est ce qui rend les trames fragmentees lisibles.
  int _trouverFinJson(String s, int depart) {
    int niveau = 0;
    bool dansChaine = false;
    for (int i = depart; i < s.length; i++) {
      final int c = s.codeUnitAt(i);
      if (c == 0x22 /* " */ ) dansChaine = !dansChaine;
      if (dansChaine) continue;
      if (c == 0x7B /* { */ ) niveau++;
      if (c == 0x7D /* } */ ) {
        niveau--;
        if (niveau == 0) return i;
      }
    }
    return -1;
  }

  /// Envoyer un message JSON a la base.
  ///
  /// Le JSON est enveloppe avec l'emetteur et la destination avant ecriture :
  /// `{"src":"DT_1500-3","dst":"BASE","payload":{...}}\r\n`. Le retour
  /// charriot marque la fin de la trame pour le parseur de la base.
  Future<bool> envoyer(
    Map<String, dynamic> payload, {
    String? destination,
  }) async {
    if (!_portSerie.ouvert) return false;
    final Map<String, dynamic> enveloppe = <String, dynamic>{
      'src': idEmetteur,
      'dst': destination ?? 'BASE',
      'payload': payload,
      'horodatage': DateTime.now().toUtc().toIso8601String(),
    };
    // Cadre delimitE par le retour charriot : c'est ce que la base utilise
    // pour decouper le flux serie (elle recoit aussi le GNSS/RTCM). Le JSON
    // ne contient jamais de saut de ligne, `jsonEncode` l'echappe.
    final String trame = '${jsonEncode(enveloppe)}\r\n';
    final Uint8List octets = Uint8List.fromList(utf8.encode(trame));
    final bool ok = await _portSerie.ecrire(octets);
    if (!ok) {
      // Port en erreur (cable debranche, module en reset) : on ne laisse pas
      // le transport croire qu'il est encore pret, sinon le badge XBee ment.
      _demarre = false;
    }
    return ok;
  }

  /// Envoie directement une position NMEA deja formatee (pas de JSON :
  /// on garde la bande passante radio au minimum).
  Future<bool> envoyerNmea(String phraseNmea) async {
    if (!_portSerie.ouvert) return false;
    return _portSerie.ecrire(
      Uint8List.fromList(utf8.encode('$phraseNmea\r\n')),
    );
  }

  /// Libere le tampon d'assemblage (une trame a moitie recue avant un arret
  /// ne doit pas contaminer la session suivante).
  void _viderTampon() => _tampon = '';

  /// Arrete le transport : ferme le port, libere les streams. Idempotent.
  Future<void> arreter() async {
    if (!_demarre) return;
    await _sub?.cancel();
    _sub = null;
    _viderTampon();
    await _portSerie.fermer();
    if (!_recus.isClosed) _recus.close();
    if (!_gga.isClosed) _gga.close();
    _demarre = false;
  }
}

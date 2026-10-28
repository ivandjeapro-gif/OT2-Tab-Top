/// Parseur NMEA 0183 pour les phrases GNSS u-blox qui arrivent sur le port
/// USB du kit ArduSimple, melangees aux cadres XBee.
///
/// Le recepteur parle par defaut NMEA sur un port, RTCM sur l'autre. Ici un
/// seul flux binaire arrive : on doit distinguer ce qui est une phrase NMEA
/// (texte `$...*hh`) de ce qui est un cadre XBee JSON ou du RTCM binaire.
/// Ce parseur bufferise les octets et rend chaque phrase NMEA COMPLETE.
class ParseurNmea {
  final StringBuffer _tampon = StringBuffer();

  /// Alimente le parseur avec des octets bruts ; rend les phrases completes.
  ///
  /// Le port serie livre les octets par morceaux — une phrase NMEA peut etre
  /// coupee en trois `onData`. On accumule donc dans un tampon et on decoupe
  /// sur les fins de ligne (`\r\n` ou `\n` seul).
  List<String> ajouter(List<int> octets) {
    for (final int o in octets) {
      if (o == 0x0A || o == 0x0D) {
        final String phrase = _tampon.toString().trim();
        _tampon.clear();
        if (phrase.isNotEmpty) {
          final List<String> sortie = <String>[];
          if (valide(phrase)) sortie.add(phrase);
          return sortie;
        }
        return const <String>[];
      }
      // Caracteres ASCII imprimables uniquement : un octet binaire (RTCM ou
      // cadre XBee) casse le tampon, on repart a zero — un texte NMEA ne
      // contient jamais d'octet hors 0x20..0x7E.
      if (o < 0x20 || o > 0x7E) {
        _tampon.clear();
        continue;
      }
      _tampon.writeCharCode(o);
    }
    return const <String>[];
  }

  /// Verifie la structure et le checksum d'une phrase NMEA.
  ///
  /// Format : `$<talker><type>,<champ1>,...*<hh>` ; le checksum XOR couvre
  /// les caracteres entre `$` et `*` exclusifs. Les phrases GLONASS
  /// (`$GL`), Galileo (`$GA`), BeiDou (`$GB`) et les multi-constellation
  /// (`$GN`) sont toutes acceptees.
  static bool valide(String phrase) {
    if (!phrase.startsWith('\$') || phrase.length < 9) return false;
    final int etoile = phrase.lastIndexOf('*');
    if (etoile < 0 || etoile + 3 > phrase.length) return false;
    final String checksum = phrase.substring(etoile + 1).trim();
    if (!RegExp(r'^[0-9A-Fa-f]{2}$').hasMatch(checksum)) return false;
    int xor = 0;
    for (int i = 1; i < etoile; i++) {
      xor ^= phrase.codeUnitAt(i);
    }
    final String calc = xor.toRadixString(16).toUpperCase().padLeft(2, '0');
    return calc == checksum.toUpperCase();
  }

  /// Decode une phrase GGA (position + fix). Rend null si ce n'est pas une
  /// GGA, ou si le fix n'est pas valide (champ `quality` = 0).
  ///
  /// Champs GGA :
  ///   0 : $GxGGA  1 : hhmmss.ss   2 : latitude ddmm.mmm
  ///   3 : N/S     4 : longitude dddmm.mmm
  ///   5 : E/W     6 : quality (0=aucun,1=GPS,2=DGPS,4=RTK fix,5=RTK float)
  ///   7 : nb satellites           8 : HDOP
  ///   9 : altitude                10 : unite
  static MesureGga? decoderGga(String phrase) {
    final List<String> morceaux = phrase.split(',');
    if (morceaux.length < 11) return null;
    final String entete = morceaux[0];
    if (!entete.endsWith('GGA')) return null;
    final int qualite = int.tryParse(morceaux[6]) ?? 0;
    if (qualite <= 0) return null;
    final double? lat = _decoderDms(morceaux[2], morceaux[3]);
    final double? lon = _decoderDms(morceaux[4], morceaux[5]);
    if (lat == null || lon == null) return null;
    return MesureGga(
      horodatage: morceaux[1],
      latitude: lat,
      longitude: lon,
      altitude: double.tryParse(morceaux[9]) ?? 0,
      qualite: qualite,
      nbSatellites: int.tryParse(morceaux[7]) ?? 0,
      hdop: double.tryParse(morceaux[8]) ?? 0,
    );
  }

  /// `ddmm.mmmm` + hemisphere -> degres decimaux signes.
  static double? _decoderDms(String valeur, String hemisphere) {
    if (valeur.length < 3) return null;
    // Latitude : 2 degres ; longitude : 3 degres.
    final int tailleDegres = hemisphere == 'N' || hemisphere == 'S' ? 2 : 3;
    final double degres =
        double.tryParse(valeur.substring(0, tailleDegres)) ?? 0;
    final double minutes = double.tryParse(valeur.substring(tailleDegres)) ?? 0;
    final double signe = (hemisphere == 'S' || hemisphere == 'W') ? -1 : 1;
    return signe * (degres + minutes / 60);
  }
}

/// Une mesure GGA deja exploitable : position WGS84 + qualite du fix.
class MesureGga {
  const MesureGga({
    required this.horodatage,
    required this.latitude,
    required this.longitude,
    required this.altitude,
    required this.qualite,
    required this.nbSatellites,
    required this.hdop,
  });

  final String horodatage;
  final double latitude;
  final double longitude;
  final double altitude;
  final int qualite;
  final int nbSatellites;
  final double hdop;

  /// Le fix est exploitable pour du tracking : RTK fix (4) ou float (5),
  /// sinon DGPS/GPS simple (1-3) reste acceptable en degradé.
  bool get exploitable => qualite > 0;

  /// Vrai si le fix est RTK (centimetrique) : qualite 4 (fix) ou 5 (float).
  bool get rtk => qualite >= 4;

  @override
  String toString() =>
      'GGA $latitude/$longitude alt=$altitude q=$qualite sat=$nbSatellites';
}

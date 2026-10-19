import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:proj4dart/proj4dart.dart' as proj;

import '../../data/base_locale.dart';

/// Source de position GPS abstraite (CDC §5, §12).
///
/// Les tablettes Android portent un GPS : le service le lit via `geolocator`
/// et pousse un evenement `GPS_UPDATE` dans la file (§12), comme toute ecriture
/// metier. L'interface est injectable : les tests utilisent un fournisseur
/// factice qui joue des positions sans materiel.
abstract class FournisseurPosition {
  /// Positions du device, au rythme du GPS. Ne leve jamais : un GPS absent
  /// ou refuse n'arrete pas l'application, il ne produit simplement rien.
  Stream<PositionTerrain> suivre();
}

/// Un point tel que le serveur l'attend (§5) : coordonnees minieres
/// (easting/northing, en metres) et altitude.
class PositionTerrain {
  const PositionTerrain({
    required this.easting,
    required this.northing,
    required this.elevation,
    this.horodatage,
    this.wgs84,
  });

  final int easting;
  final int northing;
  final int elevation;
  final DateTime? horodatage;

  /// Position WGS84 source, pour la carte de suivi (§21).
  final ({double lat, double lng})? wgs84;
}

/// Fournisseur reel : le GPS du device (Android, ou capteur de localisation
/// Windows).
///
/// La position arrive en WGS84 (degres) : elle est convertie en coordonnees
/// minieres UTM (easting/northing) avant emission, car c'est le format que
/// le serveur analyse (§5) et que les ecrans affichent deja.
///
/// Les deux plateformes n'ont pas le meme modele de permission :
/// - Android : permission runtime a demander a la premiere utilisation ;
/// - Windows : pas de permission runtime, mais le service de localisation
///   du systeme peut etre eteint — on le teste avant de s'abonner.
/// Dans tous les cas d'echec, le flux se termine vide : l'application
/// continue sans position plutot que de planter.
class GpsReel implements FournisseurPosition {
  GpsReel({
    this.intervalle = const Duration(seconds: 5),
    this.filtreDistance = 5,
  });

  /// Cadence d'echantillonnage : le GPS rafraichit plus vite que besoin,
  /// la file d'evenements n'a pas a enfler pour rien.
  final Duration intervalle;

  /// Filtre de distance (metres) : aucune mesure n'est produite tant que le
  /// device n'a pas bouge de cette distance — les vehicules immobiles ne
  /// font pas gonfler la file ni rejouer l'alerte.
  final double filtreDistance;

  /// Vrai sur Android/iOS : il faut demander la permission avant de lire.
  /// Sur web la permission est portee par le navigateur et demandee au
  /// premier appel a [geo.Geolocator] lui-meme ; [Platform] y est de toute
  /// facon indisponible (dart:io non exploitable dans le navigateur).
  static bool get _permissionsRuntime =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  @override
  Stream<PositionTerrain> suivre() async* {
    if (_permissionsRuntime) {
      // Android/iOS : permission runtime demandee une fois, refus -> flux
      // vide, l'app vit quand meme.
      geo.LocationPermission permission = await geo.Geolocator.checkPermission();
      if (permission == geo.LocationPermission.denied) {
        permission = await geo.Geolocator.requestPermission();
      }
      if (permission == geo.LocationPermission.denied ||
          permission == geo.LocationPermission.deniedForever) {
        return;
      }
    }
    // Service de localisation eteint (Windows : capteur systeme ; Android :
    // GPS desactive) : idem, rien a produire.
    if (!await geo.Geolocator.isLocationServiceEnabled()) {
      return;
    }
    // Premiere position immediate : le filtre de distance ne s'applique
    // qu'ensuite. Sans ce fix, le device immobile (tablette posee en cabine
    // avant le depart, PC de test sur un bureau) ne produit JAMAIS de
    // mesure : les tableaux restent vides et le badge reste orange, sans
    // qu'on puisse distinguer « GPS absent » de « position fixe ».
    final geo.Position premiere = await geo.Geolocator.getCurrentPosition(
      locationSettings: geo.LocationSettings(
        accuracy: geo.LocationAccuracy.best,
      ),
    ).timeout(
      const Duration(seconds: 15),
      onTimeout: () => geo.Position(
        longitude: 0,
        latitude: 0,
        timestamp: DateTime.now(),
        accuracy: -1,
        altitude: 0,
        altitudeAccuracy: 0,
        heading: 0,
        headingAccuracy: 0,
        speed: 0,
        speedAccuracy: 0,
      ),
    );
    // accuracy < 0 : le timeout a rendu son « position nulle » conventionnelle
    // — on n'en fait pas une mesure.
    if (premiere.accuracy >= 0) {
      yield _convertir(premiere);
    }
    // Puis le flux continue avec le filtre de distance : chaque mesure
    // suivante exige un deplacement d'au moins [filtreDistance] metres.
    await for (final geo.Position p in geo.Geolocator.getPositionStream(
      locationSettings: geo.LocationSettings(
        accuracy: geo.LocationAccuracy.best,
        // geolocator attend des metres entiers.
        distanceFilter: filtreDistance.round(),
        timeLimit: null,
      ),
    )) {
      yield _convertir(p);
    }
  }

  /// Conversion WGS84 -> UTM (position terrain) d'une mesure geolocator.
  PositionTerrain _convertir(geo.Position p) => PositionTerrain(
        easting: Utm.depuisWgs84(p.latitude, p.longitude).$1,
        northing: Utm.depuisWgs84(p.latitude, p.longitude).$2,
        elevation: p.altitude.round(),
        horodatage: p.timestamp,
        wgs84: (lat: p.latitude, lng: p.longitude),
      );
}

/// Conversion WGS84 -> UTM (easting/northing), via proj4dart.
///
/// Le site de travail tient dans une seule zone UTM : la zone est deduite du
/// fuselage (bande de 6 degres), la projection est la vraie UTM WGS84. Les
/// resultats sont arrondis en entiers — le serveur et les ecrans ne lisent
/// jamais de decimales (§5).
class Utm {
  Utm._();

  /// Convertit (lat, lng) WGS84 en (easting, northing) UTM.
  static (int, int) depuisWgs84(double lat, double lng) {
    // Les zones sont numerotees 1..60 pour lng -180..+180 : la formule
    // standard est floor((lng+180)/6) **+1** — sans le +1, lng 3° tombe
    // dans la zone 30 (6°O..0°) et l'easting sort du fuseau de ~500 km.
    final int zone = (((lng + 180) / 6).floor() + 1).clamp(1, 60);
    final proj.Projection utm = _projection(zone);
    final proj.Point point = proj.Projection.WGS84.transform(
      utm,
      proj.Point(x: lng, y: lat),
    );
    return (point.x.round(), point.y.round());
  }

  /// Convertit (easting, northing) UTM en (lat, lng) WGS84 — l'inverse de
  /// [depuisWgs84], pour la carte de suivi : la polyline du serveur arrive
  /// en metres UTM (CDC §4), flutter_map ne dessine qu'en degres.
  ///
  /// [zone] : fuseau UTM du site. La zone est un parametre explicite et non
  /// deduit du easting car plusieurs fuseaux produisent des coordonnees
  /// semblables ; tout le site vit dans une seule zone (§5), celle que
  /// [depuisWgs84] utilise pour les mesures GNSS.
  /// [sud] : hemisphere du site. false = nord (defaut, cas de tous les
  /// sites actuels), true = sud. Le datum UTM WGS84 s'appuie sur cette
  /// indication : sans elle, un northing de l'hemisphere sud serait lu
  /// 10 000 km trop au nord. L'appelant deduit l'hemisphere de la derniere
  /// mesure GNSS ([depuisWgs84] le fait deja cote WGS84 -> UTM).
  static ({double lat, double lng}) versWgs84(
    int easting,
    int northing, {
    int zone = 31,
    bool sud = false,
  }) {
    final proj.Projection utm = _projection(zone, sud: sud);
    final proj.Point point = utm.transform(
      proj.Projection.WGS84,
      proj.Point(x: easting.toDouble(), y: northing.toDouble()),
    );
    return (lat: point.y, lng: point.x);
  }

  /// Projection UTM WGS84 d'un fuseau, mise en cache (les ecrans convertissent
  /// a chaque mesure : parser la definition a chaque fois serait du gachis).
  static final Map<String, proj.Projection> _cacheProjections =
      <String, proj.Projection>{};

  static proj.Projection _projection(int zone, {bool sud = false}) {
    final String cle = '$zone/${sud ? 'S' : 'N'}';
    return _cacheProjections.putIfAbsent(cle, () {
      final String definition = '+proj=utm +zone=$zone +datum=WGS84 '
          '${sud ? '+south ' : ''}+units=m +no_defs';
      return proj.Projection.parse(definition);
    });
  }
}

/// Service qui suit la position du device et pose un evenement par mesure.
///
/// Branche sur la base : chaque mesure devient un `GPS_UPDATE` en file
/// `PENDING` (CDC §12), transmis au serveur comme les autres ecritures.
/// Serveur TAB 2 comme client TAB 3 : la passerelle relaie les GPS_UPDATE
/// recus du BLE dans la meme file.
class ServicePosition {
  ServicePosition({
    required this.base,
    FournisseurPosition? fournisseur,
    this.intervalle = const Duration(seconds: 5),
    this.filtreDistance = 5,
  }) : _fournisseur = fournisseur ??
            GpsReel(intervalle: intervalle, filtreDistance: filtreDistance);

  final BaseLocale base;
  final FournisseurPosition _fournisseur;
  final Duration intervalle;

  /// Filtre de distance (metres) applique par le GPS reel, lus dans
  /// `meta.filtre_distance_gps_m` a l'ouverture de la base.
  final double filtreDistance;

  StreamSubscription<PositionTerrain>? _sub;
  PositionTerrain? _derniere;

  /// Chaque mesure, diffusee en direct (flux broadcast).
  ///
  /// C'est l'entree de la detection d'ecart : la session s'abonne et compare
  /// chaque position au parcours recu du serveur, sans modifier le service.
  final StreamController<PositionTerrain> _mesures =
      StreamController<PositionTerrain>.broadcast();

  /// Mesures du GPS, au rythme de [intervalle] et du filtre de distance.
  Stream<PositionTerrain> get mesures => _mesures.stream;

  /// Derniere mesure connue, pour les ecrans (easting/northing/elevation §21).
  PositionTerrain? get derniere => _derniere;

  bool get actif => _sub != null;

  /// Demarre la surveillance GPS. Idempotent.
  void demarrer() {
    if (_sub != null) return;
    _sub = _fournisseur.suivre().listen(
      (PositionTerrain p) {
        _derniere = p;
        base.evenementPosition(p);
        _mesures.add(p);
      },
      onError: (Object _) {
        // Un GPS qui tombe n'arrete rien : la prochaine mesure reprendra.
        // Sur desktop, geolocator peut lancer une exception plateforme si le
        // service de localisation disparait en cours de route.
      },
      cancelOnError: false,
    );
  }

  void arreter() {
    _sub?.cancel();
    _sub = null;
  }
}

/// Fournisseur factice : positions scriptees, pour les tests et le banc.
class GpsFactice implements FournisseurPosition {
  GpsFactice(this.positions);

  /// Mesures a emettre, dans l'ordre. Vide ou epuise -> plus rien.
  final List<PositionTerrain> positions;

  @override
  Stream<PositionTerrain> suivre() async* {
    for (final PositionTerrain p in List<PositionTerrain>.of(positions)) {
      yield p;
    }
  }
}

/// Fournisseur de démonstration « hors parcours » : rejoue, en boucle, un
/// scénario réaliste de sortie de route.
///
/// Scénario (coordonnées UTM fictives autour d'un parcours en ligne droite) :
/// 1. le DT roule SUR le parcours (aucune alerte) ;
/// 2. il quitte la route progressivement (détour) — l'écart dépasse 40 m
///    pendant plus de 15 s → détection d'écart → alerte + bip + vibration ;
/// 3. il revient sur le parcours → alerte s'éteint ;
/// 4. après une pause, le scénario repart (boucle, pour une démo continue).
///
/// C'est un fournisseur comme un autre : la session ne sait pas qu'elle est
/// en démo, tout le reste (détection d'écart, alerter, badges) fonctionne
/// exactement comme en production.
class GpsDemoOffroad implements FournisseurPosition {
  GpsDemoOffroad({
    this.intervalle = const Duration(seconds: 2),
    this.eastingDepart = 500000,
    this.northingDepart = 718000,
    this.figerAlerte = false,
  });

  /// Cadence des mesures simulées (2 s : assez rapide pour une démo vivante).
  final Duration intervalle;

  /// Point de départ du scénario (coordonnées de la session).
  final int eastingDepart;
  final int northingDepart;

  /// Mode PRÉSENTATION : au lieu de revenir sur le parcours (et de faire
  /// retomber l'alerte), le DT reste au point d'écart maximal. Le bandeau
  /// rouge et le clignotement du cadre restent alors affichés en permanence —
  /// c'est l'état qu'on veut montrer, pas un flash de quelques secondes que
  /// l'on rate au moment de présenter l'écran.
  final bool figerAlerte;

  @override
  Stream<PositionTerrain> suivre() async* {
    int e = eastingDepart;
    int n = northingDepart;
    // Étapes du scénario : (avancée le long du parcours, écart latéral).
    // La ligne 1 suit la route (écart ~0), la 2 s'en écarte progressivement,
    // la 3 y revient, la 4 marque une pause avant de reboucler.
    final List<List<int>> detour = <List<int>>[
      // 1. Sur le parcours (~15 s de démo à 2 s/mesure).
      [0, 0], [50, 0], [100, 0], [150, 0], [200, 5], [250, 0], [300, 0],
      // 2. Détour : l'écart croît vite → dépasse 40 m → alerte.
      [350, 15], [400, 30], [450, 60], [500, 80], [550, 100],
      [600, 110], [650, 115], [700, 120], [750, 125], [800, 130],
    ];
    final List<List<int>> retour = <List<int>>[
      // 3. Retour au parcours : l'écart redescend sous 20 m.
      [850, 90], [900, 50], [950, 25], [1000, 10], [1050, 0], [1100, 0],
      [1150, 0],
      // 4. Petite pause sur place avant de reboucler.
      [1150, 0], [1150, 0],
    ];
    final List<List<int>> script = <List<int>>[
      ...detour,
      if (!figerAlerte) ...retour,
    ];
    while (true) {
      for (final List<int> etape in script) {
        final int avance = etape[0];
        final int ecart = etape[1];
        yield PositionTerrain(
          easting: e + avance,
          northing: n + ecart,
          elevation: 260,
          horodatage: DateTime.now(),
          // Pas de WGS84 fourni : la session fait elle-meme la conversion
          // UTM -> WGS84 (proj4dart, zone 30) et la carte reste coherente —
          // parcours, position du DT et destination au meme endroit.
        );
        await Future<void>.delayed(intervalle);
      }
      // Mode présentation : une fois au point d'écart maximal, on y reste —
      // l'alerte ne retombe pas, le rendu est stable pour la démonstration.
      if (figerAlerte) {
        while (true) {
          yield PositionTerrain(
            easting: e + 800,
            northing: n + 130,
            elevation: 260,
            horodatage: DateTime.now(),
          );
          await Future<void>.delayed(intervalle);
        }
      }
    }
  }
}

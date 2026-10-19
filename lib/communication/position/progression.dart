import 'dart:math' as math;

import 'detection_ecart.dart';

/// Resultat d'une mesure sur la polyline du parcours.
///
/// - [progression] : fraction du parcours deja effectuee, 0.0..1.0
///   (anti-retour applique : ne decroit jamais sur une meme polyline) ;
/// - [prochainWaypoint] : index du premier sommet non franchi. 1..n-1 ;
///   0 = rien n'est encore franchi, n = trajet termine ;
/// - [fractionWaypoint] : position du prochain waypoint sur la barre
///   (fraction de la longueur totale du parcours) ;
/// - [arrive] : vrai quand la progression atteint le bout du parcours.
class EtatProgression {
  const EtatProgression({
    required this.progression,
    required this.prochainWaypoint,
    required this.fractionWaypoint,
    required this.arrive,
  });

  final double progression;
  final int prochainWaypoint;
  final double fractionWaypoint;
  final bool arrive;
}

/// Calcul de progression le long du parcours recu du serveur (CDC §4.6).
///
/// Comme [DetecteurEcart], la classe est pure : ni timer, ni flux, ni
/// reseau. Chaque mesure GPS appelle [evaluer] avec ses coordonnees UTM
/// (metres) ; le parcours est charge par [parcours] — la polyline
/// `[[easting, northing], …]` du champ `parcours` de l'affectation.
///
/// Logique :
/// - la position est **projetee** sur le segment le plus proche : la
///   progression suit la route, meme si le DT glisse un peu a cote ;
/// - **anti-retour** : la progression garde le maximum atteint sur la
///   polyline courante (un demi-tour ne fait pas reculer la barre) ;
/// - **nouveau parcours = nouvelle histoire** : tout est remis a zero.
class CalculateurProgression {
  String? _brut;
  List<PointParcours>? _points;
  List<double>? _longueursCumulees;
  double _longueurTotale = 0;
  double _progression = 0;
  int _prochainWaypoint = 0;

  /// Vrai quand un parcours exploitable est charge.
  bool get actif => _points != null;

  /// Derniere progression calculee (0.0..1.0), ou la valeur memorisee.
  double get progression => _progression;

  /// Premier sommet non franchi de la polyline courante.
  int get prochainWaypoint => _prochainWaypoint;

  /// Fraction de la longueur totale a laquelle se trouve le prochain
  /// waypoint (pour l'afficher sur la barre de trajet).
  double get fractionWaypoint {
    final List<PointParcours>? points = _points;
    if (points == null || points.length < 2) return 0;
    final int index = _prochainWaypoint.clamp(1, points.length - 1);
    final double cumule = _longueursCumulees![index - 1];
    return _longueurTotale <= 0 ? 0 : (cumule / _longueurTotale).clamp(0.0, 1.0);
  }

  /// Charge le parcours recu du serveur (champ `parcours` de l'affectation).
  ///
  /// Une chaine identique n'est pas reparse (appel a chaque mesure GPS).
  /// Un nouveau parcours remet la progression a zero.
  void parcours(String? brut) {
    if (brut == _brut) return;
    _brut = brut;
    _points = DetecteurEcart.parserPolyline(brut);
    final List<PointParcours>? points = _points;
    if (points == null || points.length < 2) {
      _points = null;
      _longueursCumulees = null;
      _longueurTotale = 0;
      _progression = 0;
      _prochainWaypoint = 0;
      return;
    }
    // Longueurs cumulees : somme des segments jusqu'a chaque sommet.
    final List<double> cumulees = <double>[0];
    double total = 0;
    for (int i = 1; i < points.length; i++) {
      total += _longueur(points[i - 1], points[i]);
      cumulees.add(total);
    }
    _longueursCumulees = cumulees;
    _longueurTotale = total;
    _progression = 0;
    _prochainWaypoint = 0;
  }

  /// Une mesure GPS : met a jour la progression et le prochain waypoint.
  EtatProgression evaluer({required double easting, required double northing}) {
    final List<PointParcours>? points = _points;
    if (points == null || points.length < 2) {
      return EtatProgression(
        progression: _progression,
        prochainWaypoint: _prochainWaypoint,
        fractionWaypoint: fractionWaypoint,
        arrive: false,
      );
    }

    // Projection sur chaque segment : on garde la meilleure (la plus proche).
    double meilleure = double.infinity;
    int indexSegment = 0;
    double tSegment = 0;
    for (int i = 0; i < points.length - 1; i++) {
      final (double t, double d) = _projet(
        points[i],
        points[i + 1],
        easting,
        northing,
      );
      if (d < meilleure) {
        meilleure = d;
        indexSegment = i;
        tSegment = t;
      }
    }

    // Distance le long du parcours jusqu'a la position projetee.
    final double cumule = _longueursCumulees![indexSegment] +
        _longueur(points[indexSegment], points[indexSegment + 1]) * tSegment;
    final double brute = _longueurTotale <= 0
        ? 0
        : (cumule / _longueurTotale).clamp(0.0, 1.0);

    // Anti-retour : la progression ne decroit jamais sur une polyline.
    if (brute > _progression) _progression = brute;

    // Prochain waypoint : premier sommet non franchi par la projection.
    // Le sommet i est franchi des que le cumule depasse sa longueur cumulee.
    int prochain = points.length - 1;
    for (int i = 1; i < points.length; i++) {
      if (cumule < _longueursCumulees![i] - 0.5) {
        prochain = i;
        break;
      }
    }
    _prochainWaypoint = prochain;

    return EtatProgression(
      progression: _progression,
      prochainWaypoint: prochain,
      fractionWaypoint: fractionWaypoint,
      arrive: _progression >= 0.999,
    );
  }

  /// Longueur euclidienne d'un segment, en metres (UTM).
  static double _longueur(PointParcours a, PointParcours b) {
    final double dx = b.easting - a.easting;
    final double dy = b.northing - a.northing;
    return math.sqrt(dx * dx + dy * dy);
  }

  /// Projette (easting, northing) sur le segment [a, b] :
  /// retourne (t, distance) — t = parametre le long du segment (0..1).
  static (double, double) _projet(
    PointParcours a,
    PointParcours b,
    double x,
    double y,
  ) {
    final double dx = b.easting - a.easting;
    final double dy = b.northing - a.northing;
    final double longueur2 = dx * dx + dy * dy;
    if (longueur2 <= 0) {
      return (
        0,
        math.sqrt((x - a.easting) * (x - a.easting) +
            (y - a.northing) * (y - a.northing)),
      );
    }
    double t = ((x - a.easting) * dx + (y - a.northing) * dy) / longueur2;
    t = t.clamp(0.0, 1.0).toDouble();
    final double px = a.easting + t * dx;
    final double py = a.northing + t * dy;
    final double d = math.sqrt((x - px) * (x - px) + (y - py) * (y - py));
    return (t, d);
  }

  /// Decodage de la polyline `[[easting, northing], …]`, delegue a
  /// [DetecteurEcart] pour un seul parser (meme format, meme regles).
  static List<PointParcours>? parser(String? brut) =>
      DetecteurEcart.parserPolyline(brut);
}

import 'dart:convert';
import 'dart:math';

/// Un point du parcours, en coordonnees minieres UTM (metres, CDC §5).
typedef PointParcours = ({double easting, double northing});

/// Detection d'ecart au parcours vers la dumping area (option B).
///
/// Le serveur pose une cle `parcours` — polyline `[[easting, northing], …]` —
/// dans `/affectation` ; la tablette mesure la distance de sa position GPS a
/// ce parcours et signale la sortie de route. Le comparateur est local :
/// il ne depend d'aucun reseau une fois le parcours recu.
///
/// Regles (validees avec l'utilisateur) :
/// - entree : **40 m** depasses pendant **15 s** ;
/// - sortie : retour sous **20 m**, immediat ;
/// - entre 20 et 40 m : l'etat precedent est conserve (hysterisis).
///
/// La classe est pure : ni timer, ni flux, ni plateforme. Chaque mesure GPS
/// appelle [evaluer] avec son propre horodatage, ce qui rend les seuils de
/// temps testables sans attendre le GPS reel.
class DetecteurEcart {
  DetecteurEcart({
    this.seuilEntree = 40,
    this.seuilSortie = 20,
    this.delaiConfirmation = const Duration(seconds: 15),
  }) : assert(seuilSortie < seuilEntree);

  /// Distance a partir de laquelle le DT est considere hors parcours.
  double seuilEntree;

  /// Distance en dessous de laquelle le DT est de nouveau sur le parcours.
  double seuilSortie;

  /// Temps pendant lequel l'ecart doit rester au dessus de [seuilEntree]
  /// avant de declencher : une mesure isolée (bruit GPS) n'alerte pas.
  Duration delaiConfirmation;

  /// Reapplique les seuils en cours de route (ecran Parametres, cles
  /// `seuil_entree_m` / `seuil_sortie_m` / `delai_confirmation_s`).
  ///
  /// Le parcours deja charge et l'etat courant sont conserves : seul le
  /// comparateur change, sans nouvelle lecture du serveur. Retourne false
  /// sans rien modifier si la configuration est incoherente (le seuil de
  /// sortie doit rester strictement inferieur au seuil d'entree).
  bool configurer({
    double? seuilEntree,
    double? seuilSortie,
    Duration? delaiConfirmation,
  }) {
    final double entree = seuilEntree ?? this.seuilEntree;
    final double sortie = seuilSortie ?? this.seuilSortie;
    if (!(sortie < entree)) return false;
    this.seuilEntree = entree;
    this.seuilSortie = sortie;
    this.delaiConfirmation = delaiConfirmation ?? this.delaiConfirmation;
    // L'ancien compteur de confirmation a ete mesure avec les anciens
    // seuils : il repart de zero plutot que de valider un alerte ancienne.
    _depuis = null;
    return true;
  }

  String? _brut;
  List<PointParcours>? _points;
  bool _horsParcours = false;
  DateTime? _depuis;
  double? _distance;

  /// Vrai quand un parcours exploitable a ete charge : c'est lui qui active
  /// la detection locale (sinon la session se rabat sur l'`alerte` serveur).
  bool get actif => _points != null;

  /// Etat courant : le DT est sorti du parcours.
  bool get horsParcours => _horsParcours;

  /// Derniere distance mesuree au parcours (metres), pour le bandeau.
  double? get derniereDistance => _distance;

  /// Charge le parcours recu du serveur (champ `parcours` de l'affectation).
  ///
  /// `null`, vide ou malforme : le detecteur devient inactif sans jamais
  /// lever — un serveur qui envoie n'importe quoi ne casse pas la tablette.
  /// Une chaine identique n'est pas reparsée (appel a chaque mesure GPS).
  void parcours(String? brut) {
    if (brut == _brut) return;
    _brut = brut;
    _points = parserPolyline(brut);
    // Nouveau trajet = nouvelle histoire : pas de reliquat de l'ancien.
    _horsParcours = false;
    _depuis = null;
    _distance = null;
  }

  /// Decode `[[easting, northing], …]` : au moins deux points numeriques.
  /// Decode une polyline `[[easting, northing], …]` recue du serveur.
  ///
  /// Public car le calculateur de progression ([progression.dart]) lit le
  /// meme champ `parcours` : un seul parser, un seul format.
  static List<PointParcours>? parserPolyline(String? brut) {
    if (brut == null || brut.isEmpty) return null;
    try {
      final Object? brut2 = jsonDecode(brut);
      if (brut2 is! List || brut2.length < 2) return null;
      final List<PointParcours> points = <PointParcours>[];
      for (final Object? p in brut2) {
        if (p is! List || p.length < 2) return null;
        final Object? e = p[0];
        final Object? n = p[1];
        if (e is! num || n is! num) return null;
        points.add((easting: e.toDouble(), northing: n.toDouble()));
      }
      return points;
    } on FormatException {
      return null;
    }
  }

  /// Une mesure GPS : met a jour l'etat et retourne [horsParcours].
  ///
  /// [maintenant] vient de la mesure (horodatage du GPS) : le delai de
  /// confirmation se compte en temps reel, pas en nombre de mesures.
  bool evaluer({
    required double easting,
    required double northing,
    required DateTime maintenant,
  }) {
    final List<PointParcours>? points = _points;
    if (points == null) return false;

    final double d = _distanceAuParcours(points, easting, northing);
    _distance = d;

    if (_horsParcours) {
      // Retour sur le trajet : immediat, il n'y a rien a confirmer.
      if (d < seuilSortie) {
        _horsParcours = false;
        _depuis = null;
      }
    } else if (d > seuilEntree) {
      // Sortie : elle ne compte qu'apres [delaiConfirmation] continue.
      _depuis ??= maintenant;
      if (maintenant.difference(_depuis!) >= delaiConfirmation) {
        _horsParcours = true;
      }
    } else {
      // Revenu dans la bande : le compteur de confirmation repart a zero.
      _depuis = null;
    }
    return _horsParcours;
  }

  /// Distance minimale (metres) du point a la polyline, en projection
  /// euclidienne UTM : le site tient dans un seul fuseau, les metres UTM
  /// sont des metres reels.
  static double _distanceAuParcours(
    List<PointParcours> points,
    double x,
    double y,
  ) {
    double meilleur = double.infinity;
    for (int i = 0; i + 1 < points.length; i++) {
      final double d = _distanceAuSegment(
        points[i],
        points[i + 1],
        x,
        y,
      );
      if (d < meilleur) meilleur = d;
    }
    return meilleur;
  }

  /// Distance du point (x, y) au segment [a]-[b], avec projection sur le
  /// segment (les extremites sont des sommets du trajet, pas des perpendiculaires).
  static double _distanceAuSegment(
    PointParcours a,
    PointParcours b,
    double x,
    double y,
  ) {
    final double dx = b.easting - a.easting;
    final double dy = b.northing - a.northing;
    final double longueur2 = dx * dx + dy * dy;
    if (longueur2 == 0) {
      // Segment reduit a un point.
      return sqrt((x - a.easting) * (x - a.easting) +
          (y - a.northing) * (y - a.northing));
    }
    double t = ((x - a.easting) * dx + (y - a.northing) * dy) / longueur2;
    t = t.clamp(0.0, 1.0).toDouble();
    final double px = a.easting + t * dx;
    final double py = a.northing + t * dy;
    return sqrt((x - px) * (x - px) + (y - py) * (y - py));
  }
}

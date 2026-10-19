import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../theme/app_theme.dart';

/// Carte de suivi du DT : fond OpenStreetMap, parcours recu du serveur
/// (polyline superposee aux tuiles), portion parcourue en vert, position
/// reelle du DT et destination marquees.
///
/// La carte ne lit rien elle meme : elle recoit des points que la session a
/// deja lus dans la base. Le recadrage se fait par la cle du `FlutterMap`,
/// donc uniquement quand la destination change - un tick de synchro de plus
/// deplace le DT sans jamais faire sauter le zoom choisi a la main.
class CarteSuivi extends StatelessWidget {
  const CarteSuivi({
    super.key,
    required this.destination,
    required this.arrivee,
    this.depart,
    this.position,
    this.parcours,
    this.positionParcourue,
    this.libelleDestination,
  });

  /// Code de la destination : c'est lui qui pilote le recadrage.
  final String destination;

  /// Point de depart du trajet. Absent => pas de trace, seulement un point.
  final ({double lat, double lng})? depart;

  /// Destination a atteindre.
  final ({double lat, double lng})? arrivee;

  /// Position reelle du DT (mesure GNSS en WGS84).
  final ({double lat, double lng})? position;

  /// Parcours recue du serveur, convertie en WGS84 : la polyline complete
  /// (noire) superposee aux tuiles OpenStreetMap. Absente => la carte
  /// retombe sur le trajet depart->arrivee a deux points.
  final List<({double lat, double lng})>? parcours;

  /// Portion deja parcourue du parcours (jusqu'a la position reelle, point
  /// projeté inclus) : dessinee en vert par-dessus la polyline noire.
  final List<({double lat, double lng})>? positionParcourue;

  final String? libelleDestination;

  LatLng _latLng(({double lat, double lng}) p) => LatLng(p.lat, p.lng);

  @override
  Widget build(BuildContext context) {
    final ({double lat, double lng})? arrivee = this.arrivee;
    if (arrivee == null) return const SizedBox.shrink();

    final ({double lat, double lng})? depart = this.depart;
    final ({double lat, double lng})? position = this.position;

    // Polyline du serveur (waypoints) : utilisee telle quelle si elle est
    // la, sinon repli sur le trajet a deux points depart -> arrivee.
    final List<({double lat, double lng})>? parcours = this.parcours;
    final List<LatLng> traceComplet = parcours != null && parcours.length >= 2
        ? parcours.map(_latLng).toList()
        : <LatLng>[
            if (depart != null) _latLng(depart),
            _latLng(arrivee),
          ];

    // Portion parcourue : si la session a projete la position sur le
    // parcours, elle fournit la trace tronquee ; sinon la portion dessinee
    // reste depart -> position (vieux comportement, sans polyline).
    final List<({double lat, double lng})>? parcouru = positionParcourue;
    final bool traceVerte = parcouru != null && parcouru.length >= 2;
    final List<LatLng> traceParcouru = traceVerte
        ? parcouru.map(_latLng).toList()
        : <LatLng>[
            if (depart != null && position != null) _latLng(depart),
            if (depart != null && position != null) _latLng(position),
          ];

    // Les points connus encadrent le trajet : on cadre dessus, avec une
    // marge pour que rien ne colle au bord. maxZoom empeche deux points
    // proches de zoomer jusqu'a des carreaux illisibles.
    final List<LatLng> points = [
      if (depart != null) _latLng(depart),
      _latLng(arrivee),
      if (position != null) _latLng(position),
      ...traceComplet,
    ];

    // L'attribution vit hors de la carte, en overlay : celle de flutter_map
    // n'est pas elargie par la fenetre et deborde des que la carte retrecit.
    // Le cadrage initial ne s'applique qu'a la creation de la FlutterMap :
    // on la recre (meme destination, meme zoom) quand les donnees deviennent
    // disponibles — arrivée de la position du DT, puis du trace parcouru —
    // sinon la carte reste cadree sur ses seuls premiers points (parcours
    // invisible). Une fois ces donnees la, la cle ne change plus et le
    // deplacement/zoom manuel de l'utilisateur est preserve.
    final String cleCadrage = 'carte-'
        '$destination-${position != null}-$traceVerte-$traceComplet.length';
    return ClipRRect(
      child: Stack(
        fit: StackFit.passthrough,
        children: [
          FlutterMap(
            key: ValueKey<String>(cleCadrage),
            options: MapOptions(
              initialCameraFit: CameraFit.bounds(
                bounds: LatLngBounds.fromPoints(points),
                padding: const EdgeInsets.all(48),
                maxZoom: 17,
              ),
              // La rotation d'un plan de mine se brouille vite : on garde le
              // nord en haut et on laisse zoom/deplacer.
              interactionOptions: const InteractionOptions(
                flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
              ),
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.oretracking.ore_tracking',
                maxZoom: 19,
              ),
              // Trace complet en noir (polyline serveur superposee aux
              // tuiles), puis la partie deja parcourue en vert : la meme
              // lecture que la barre de trajet sous le tableau.
              PolylineLayer(
                polylines: [
                  Polyline(
                    points: traceComplet,
                    strokeWidth: 4,
                    color: Colors.black,
                  ),
                  Polyline(
                    points: traceParcouru,
                    strokeWidth: 4,
                    color: AppColors.green,
                  ),
                ],
              ),
              MarkerLayer(
                markers: [
                  if (depart != null)
                    Marker(
                      point: _latLng(depart),
                      width: 28,
                      height: 28,
                      child: Container(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.white,
                          border: Border.fromBorderSide(
                            BorderSide(color: Colors.black, width: 2.5),
                          ),
                        ),
                      ),
                    ),
                  Marker(
                    point: _latLng(arrivee),
                    width: 110,
                    height: 64,
                    // Le drapeau doit se poser sur la destination : le bas du
                    // widget est ancre au point, pas son centre.
                    alignment: Alignment.bottomCenter,
                    child: _Destination(
                      libelle: libelleDestination ?? destination,
                    ),
                  ),
                  if (position != null)
                    Marker(
                      point: _latLng(position),
                      width: 40,
                      height: 40,
                      child: const _DtDemining(),
                    ),
                ],
              ),
            ],
          ),
          const Positioned(
            right: 4,
            bottom: 4,
            child: _Attribution(),
          ),
        ],
      ),
    );
  }
}

/// Mention « © OpenStreetMap » sous la carte : le texte se reduit (une seule
/// ligne, ellipse) plutot que de deborder quand la carte est etroite.
class _Attribution extends StatelessWidget {
  const _Attribution();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.white70,
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
      child: const Text(
        '© OpenStreetMap',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontFamily: kSerif,
          fontSize: 11,
          color: Colors.black54,
        ),
      ),
    );
  }
}

/// Destination : un drapeau noir, avec son code pose au dessus.
class _Destination extends StatelessWidget {
  const _Destination({required this.libelle});

  final String libelle;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(color: AppColors.ink, width: 1.5),
          ),
          child: Text(
            libelle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontFamily: kSerif,
              fontSize: 13,
              color: AppColors.ink,
            ),
          ),
        ),
        const Icon(Icons.location_on, size: 30, color: Colors.black),
      ],
    );
  }
}

/// Le DT : pastille verte a l'ecusson demineur (DT = demining team),
/// cohérente avec les badges du reseau.
class _DtDemining extends StatelessWidget {
  const _DtDemining();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: AppColors.green,
        border: Border.all(color: Colors.white, width: 3),
        boxShadow: const [
          BoxShadow(color: Colors.black26, blurRadius: 4),
        ],
      ),
      // Le marqueur represente un vehicule de deminage, pas un camion de
      // fret : le bouclier (safe/demining) plutot que le camion.
      child: const Icon(Icons.shield, size: 20, color: Colors.white),
    );
  }
}

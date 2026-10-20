import 'package:flutter/material.dart';

import '../state/etat_couche.dart';
import '../state/session.dart';

/// Quel ensemble de voyants afficher dans le bandeau du haut.
///
/// Le bandeau est commun aux trois profils ; ce sont les couches qui changent :
///
/// - **DT** : 4G (serveur), BLE (excavatrice), Wi-Fi (point d'acces), GPS.
/// - **Excavatrice** : GPS, point d'acces, BLE. Pas de 4G : ce n'est pas elle
///   qui porte la liaison serveur, c'est le DT.
/// - **Spotter** : 4G, BLE, Wi-Fi. Pas de GPS : ce profil n'embarque aucun
///   recepteur, et faire tourner le service remplirait la file d'evenements
///   de mesures fantomes.
enum ProfilVoyants { dt, excavatrice, spotter }

/// Un voyant du bandeau : icone + libelle court, cadre de la couleur d'etat.
///
/// Geometrie dediee au bandeau. Les badges d'ecran (`GsmStatusBadge` et
/// compagnie) sont dessines pour 80 x 70 px : les réduire dans une boite
/// etroite les rendait invisibles a l'ecran.
class VoyantBandeau extends StatelessWidget {
  const VoyantBandeau({
    super.key,
    required this.icone,
    required this.couleur,
    required this.libelle,
    this.aide,
    this.cote = 52,
  });

  final IconData icone;
  final Color couleur;

  /// Libelle ultra-court : ON / ... / OFF.
  final String libelle;

  /// Infobulle : dit precisement de quelle couche il s'agit.
  final String? aide;

  /// Cote du carre, en pixels logiques.
  ///
  /// Le bandeau vaut 96 px sur tablette, mais se reduit sur les petits
  /// formats : 64 debordait de 18 px une fois compresse. 52 passe partout
  /// et reste nettement plus lisible que 32.
  final double cote;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: aide ?? libelle,
      child: Container(
        width: cote,
        height: cote,
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: couleur, width: 2.5),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icone, size: cote * 0.44, color: couleur),
            const SizedBox(height: 1),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                libelle,
                maxLines: 1,
                style: TextStyle(
                  fontSize: cote * 0.24,
                  height: 1.0,
                  fontWeight: FontWeight.w800,
                  color: couleur,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Voyants poses dans le bandeau gris du haut.
class VoyantsEntete extends StatelessWidget {
  const VoyantsEntete({
    super.key,
    required this.session,
    required this.profil,
  });

  final Session session;
  final ProfilVoyants profil;

  /// Libelle court d'un etat.
  static String _court(EtatCouche e) => switch (e) {
        EtatCouche.connecte => 'ON',
        EtatCouche.recherche => '...',
        EtatCouche.arret => 'OFF',
      };

  @override
  Widget build(BuildContext context) {
    final List<Widget> badges = switch (profil) {
      ProfilVoyants.dt => <Widget>[
          VoyantBandeau(
            icone: Icons.signal_cellular_alt,
            couleur: session.etat4GAffiche.couleur,
            libelle: _court(session.etat4GAffiche),
            aide: '4G : liaison au serveur',
          ),
          VoyantBandeau(
            icone: Icons.bluetooth,
            couleur: session.etatBleAffiche.couleur,
            libelle: _court(session.etatBleAffiche),
            aide: 'BLE : lien avec l\'excavatrice',
          ),
          VoyantBandeau(
            icone: Icons.wifi,
            couleur: session.etatWifiAffiche.couleur,
            libelle: _court(session.etatWifiAffiche),
            aide: 'Wi-Fi : point d\'acces de l\'excavatrice',
          ),
          VoyantBandeau(
            icone: Icons.satellite_alt,
            couleur: session.etatGpsAffiche.couleur,
            libelle: _court(session.etatGpsAffiche),
            aide: 'GPS : source ${session.libelleSourcePosition}',
          ),
        ],
      ProfilVoyants.excavatrice => <Widget>[
          VoyantBandeau(
            icone: Icons.satellite_alt,
            couleur: session.etatGps.couleur,
            libelle: _court(session.etatGps),
            aide: 'GPS : source ${session.libelleSourcePosition}',
          ),
          VoyantBandeau(
            icone: Icons.wifi_tethering,
            couleur: session.etatPointAcces.couleur,
            libelle: _court(session.etatPointAcces),
            aide: session.ssidExcavatrice.isEmpty
                ? 'Point d\'acces : ferme'
                : 'Point d\'acces : ${session.ssidExcavatrice}',
          ),
          VoyantBandeau(
            icone: Icons.bluetooth,
            couleur: session.etatBle.couleur,
            libelle: _court(session.etatBle),
            aide: 'BLE : lien avec les DT',
          ),
        ],
      ProfilVoyants.spotter => <Widget>[
          VoyantBandeau(
            icone: Icons.signal_cellular_alt,
            couleur: session.etat4GAffiche.couleur,
            libelle: _court(session.etat4GAffiche),
            aide: '4G : liaison au serveur',
          ),
          VoyantBandeau(
            icone: Icons.bluetooth,
            couleur: session.etatBleAffiche.couleur,
            libelle: _court(session.etatBleAffiche),
            aide: 'BLE : lien avec l\'excavatrice',
          ),
          VoyantBandeau(
            icone: Icons.wifi,
            couleur: session.etatWifiAffiche.couleur,
            libelle: _court(session.etatWifiAffiche),
            aide: 'Wi-Fi : point d\'acces de l\'excavatrice',
          ),
        ],
    };

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (int i = 0; i < badges.length; i++) ...[
          if (i > 0) const SizedBox(width: 6),
          badges[i],
        ],
      ],
    );
  }
}

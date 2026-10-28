import 'package:flutter/material.dart';

import '../state/session.dart';
import '../theme/responsive.dart';
import 'status_badges.dart';

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

/// Voyants compacts poses dans le bandeau gris du haut.
///
/// Ils sont volontairement petits : le bandeau mesure [MiseEnPage.hauteurEntete]
/// et les logos occupent le centre. Un voyant doit rester lisible sans
/// pousser le nom de l'equipement hors du cadre.
class VoyantsEntete extends StatelessWidget {
  const VoyantsEntete({super.key, required this.session, required this.profil});

  final Session session;
  final ProfilVoyants profil;

  @override
  Widget build(BuildContext context) {
    // AUCUNE taille fixe ici. Les voyants gardent leur taille de reference
    // (`MiseEnPage.tailleBadge`, 78x66 bornee selon l'ecran), exactement comme
    // sur les ecrans DT (`dt_screen`) et excavator (`excavator_screen`).
    //
    // Historique : un carre de 30 px entourait chaque badge pour le faire
    // tenir dans le bandeau. Le `FittedBox` reduisait alors tout le contenu a
    // environ 45 % — icone de 30 px rendue a 13 px, libelle de 13 sp rendu a
    // 6 sp : les voyants du spotter etaient 2,6 fois plus petits que ceux des
    // autres profils (constat du 26/10).
    //
    // Le bandeau mesure `hauteurEntete` (96 px) : un badge de 66 px de haut y
    // tient sans contrainte. Le `FittedBox` est CONSERVE, mais seulement comme
    // filet de securite : sur un ecran exceptionnellement etroit il reduit le
    // badge au lieu de provoquer un debordement de ligne (`RenderFlex
    // overflow`), alors qu'un `SizedBox` de taille imposee deborderait.
    final double k = MiseEnPage.depuis(context).k;

    Widget voyant(Widget badge) => FittedBox(
      fit: BoxFit.scaleDown,
      child: badge,
    );

    // Les voyants suivent les OPTIONS DE CONNEXION des Parametres : un
    // transport non coche n'existe pas a l'ecran — on n'affiche ni son
    // badge, ni un etat « inactif » qui genererait une fausse alerte.
    // Le hotspot (de repli) n'apparait que s'il est coche ET qu'aucun
    // transport prioritaire (BLE/XBee) ne l'ecrase — cf. demarrerCouches.
    final List<Widget> badges = switch (profil) {
      // Ordre de lecture : ce qui sort du site, puis ce qui circule sur le
      // site, puis la position.
      ProfilVoyants.dt => <Widget>[
          voyant(GsmStatusBadge(etat: session.etat4GAffiche)),
          if (session.transportBleActif)
            voyant(BleStatusBadge(etat: session.etatBleAffiche)),
          if (session.transportXbeeActif)
            voyant(XbeeStatusBadge(etat: session.etatXbeeAffiche)),
          if (session.transportHotspotActif && !session.transportPrioritaireActif)
            voyant(WifiP2pStatusBadge(etat: session.etatWifiAffiche)),
          voyant(GpsStatusBadge(etat: session.etatGpsAffiche, remplir: true)),
        ],
      ProfilVoyants.excavatrice => <Widget>[
          voyant(GpsStatusBadge(etat: session.etatGps)),
          if (session.transportHotspotActif && !session.transportPrioritaireActif)
            voyant(
              PointAccesStatusBadge(
                etat: session.etatPointAcces,
                ssid: session.ssidExcavatrice,
              ),
            ),
          if (session.transportBleActif)
            voyant(BleStatusBadge(etat: session.etatBle)),
          if (session.transportXbeeActif)
            voyant(XbeeStatusBadge(etat: session.etatXbee)),
        ],
      ProfilVoyants.spotter => <Widget>[
          voyant(GsmStatusBadge(etat: session.etat4GAffiche)),
          if (session.transportBleActif)
            voyant(BleStatusBadge(etat: session.etatBleAffiche)),
          if (session.transportXbeeActif)
            voyant(XbeeStatusBadge(etat: session.etatXbeeAffiche)),
          if (session.transportHotspotActif && !session.transportPrioritaireActif)
            voyant(WifiP2pStatusBadge(etat: session.etatWifiAffiche)),
        ],
    };

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (int i = 0; i < badges.length; i++) ...[
          // Ecart proportionnel a l'ecran : les badges etant plus larges
          // qu'avant, 4 px les collaient les uns aux autres sur tablette.
          if (i > 0) SizedBox(width: 8 * k),
          badges[i],
        ],
      ],
    );
  }
}

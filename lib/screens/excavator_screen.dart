import 'package:flutter/material.dart';

import '../state/etat_couche.dart';
import '../state/session.dart';
import '../theme/app_theme.dart';
import '../theme/responsive.dart';
import '../widgets/profile_shell.dart';
import '../widgets/status_badges.dart';

/// Ecran de l'excavatrice : compteurs E/N/E rafraichis a chaque synchro.
class ExcavatorScreen extends StatelessWidget {
  const ExcavatorScreen({super.key, required this.session});

  final Session session;

  @override
  Widget build(BuildContext context) {
    return ProfileShell(
      session: session,
      body: ListenableBuilder(
        listenable: session,
        builder: (context, _) {
          // Meme mise en page que les deux autres ecrans profils : meme
          // marge, memes echelles, donc les blocs commencent aux memes
          // coordonnees d'un ecran a l'autre.
          final MiseEnPage mise = MiseEnPage.depuis(context);
          final double k = mise.k;

          // Mise en page proportionnelle ; cette vue utilise le tableau
          // pleine largeur sur toutes les tailles.
          return Padding(
            padding: mise.margeEcran,
            // Aucun defilement : le contenu tient entierement dans la zone
            // laissee par le shell (en-tete + bandeau de notifications).
            // La repartition verticale est en pourcentages stables
            // (flex 9 / 16 / 16 / 1) : ajouter ou retirer un bloc ne decale
            // pas les autres, il redistribue la meme hauteur disponible.
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Badge de gauche : le GPS **de l'excavatrice**. La position
                    // du DT est celle qui decrit le site, mais c'est de cette
                    // tablette que part la moyenne de perle : sans GPS ici,
                    // aucune moyenne n'a de sens.
                    //
                    // Plus de badge 4G : l'excavatrice ne porte pas la liaison
                    // serveur (c'est le DT qui la porte et qui pousse les
                    // evenements). L'ancien voyant restait rouge en permanence
                    // sans rien signaler de reel.
                    SizedBox(
                      width: mise.tailleBadge.width,
                      height: mise.tailleBadge.height,
                      child: GpsStatusBadge(etat: session.etatGps),
                    ),
                    Expanded(
                      child: Center(
                        child: Column(
                          children: [
                            Text(
                              session.deviceName.isEmpty
                                  ? (session.profile?.titre ?? 'Excavator')
                                  : session.deviceName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontFamily: kSerif,
                                fontSize: (28 * k).clamp(18.0, 28.0),
                                color: AppColors.ink,
                              ),
                            ),
                            SizedBox(height: 4 * k),
                            // Etat de la session perle : quel DT est connecte
                            // et combien de positions ont ete accumulees
                            // (§2.3). "Aucun DT" remplace le "Synchro #n" des
                            // que la couche BLE est inversee cote excavator.
                            Text(
                              session.dtConnecte.isEmpty
                                  ? 'Aucun DT dans le rayon'
                                  : 'DT ${session.dtConnecte} · '
                                      '${session.positionsPerle} position(s)',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontFamily: kSerif,
                                fontSize: (12 * k).clamp(9.0, 12.0),
                                color: const Color(0xFF6E7278),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    // A droite du nom, les deux liens qui font vivre le
                    // terrain : le point d'acces (le reseau que les autres
                    // tablettes rejoignent) et le BLE (le lien qui porte la
                    // proximite de 10 m et la session perle).
                    SizedBox(width: 8 * k),
                    SizedBox(
                      width: mise.tailleBadge.width,
                      height: mise.tailleBadge.height,
                      child: PointAccesStatusBadge(
                        etat: session.etatPointAcces,
                        ssid: session.ssidExcavatrice,
                      ),
                    ),
                    SizedBox(width: 8 * k),
                    SizedBox(
                      width: mise.tailleBadge.width,
                      height: mise.tailleBadge.height,
                      child: BleStatusBadge(etat: session.etatBle),
                    ),
                  ],
                ),
                // Ecart proportionnel : il fait partie de la repartition
                // verticale (flex), pas une hauteur fixe qui decale le bas.
                Expanded(
                  flex: 9,
                  child: SizedBox(
                    height: 22 * k,
                  ),
                ),
                Expanded(
                  flex: 116,
                  child: Container(
                    decoration: BoxDecoration(
                      border: Border.all(color: AppColors.border, width: 1.5),
                    ),
                    // L'en-tete et les valeurs se partagent la hauteur
                    // disponible : le tableau se resserre avec la fenetre au
                    // lieu d'ajouter des hauteurs fixes et de deborder.
                    child: Column(
                      children: [
                        Expanded(
                          flex: 64,
                          child: Container(
                            color: AppColors.tan,
                            child: IntrinsicHeight(
                              child: Row(
                                children: [
                                  for (var i = 0; i < 3; i++) ...[
                                    if (i > 0)
                                      Container(
                                        width: 1.5,
                                        color: AppColors.border,
                                      ),
                                    Expanded(
                                      child: Container(
                                        height: double.infinity,
                                        alignment: Alignment.center,
                                        child: FittedBox(
                                          fit: BoxFit.scaleDown,
                                          child: Text(
                                            const [
                                              'Easting',
                                              'Northing',
                                              'Elevation',
                                            ][i],
                                            style: TextStyle(
                                              fontFamily: kSerif,
                                              fontSize: (15 * k).clamp(10.0, 15.0),
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        ),
                        Expanded(
                          flex: 180,
                          child: Container(
                            color: Colors.white,
                            alignment: Alignment.center,
                            child: Row(
                              children: [
                                for (var i = 0; i < 3; i++) ...[
                                  if (i > 0)
                                    Container(
                                      width: 2.5,
                                      height: double.infinity,
                                      color: AppColors.ink,
                                    ),
                                  Expanded(
                                    child: FittedBox(
                                      fit: BoxFit.scaleDown,
                                      child: Padding(
                                        padding: EdgeInsets.symmetric(
                                          horizontal: 12 * k,
                                        ),
                                        child: Text(
                                          i == 0
                                              ? '${session.easting}'
                                              : i == 1
                                                  ? '${session.northing}'
                                                  : '${session.elevation}',
                                          style: TextStyle(
                                            fontFamily: kSerif,
                                            fontSize: (40 * k).clamp(18.0, 40.0),
                                            color: AppColors.ink,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                // Ecart proportionnel entre les deux tableaux (flex), pour
                // que rien ne soit fige en pixels et que le tout tienne dans
                // la zone utile du shell.
                Expanded(
                  flex: 9,
                  child: SizedBox(
                    height: 10 * k,
                  ),
                ),
                // Moyenne de la perle sur la session en cours (§2.3) :
                // envoyee au DT a la sortie de zone, "c'est cette moyenne qui
                // doit etre envoyee au serveur". Valeurs recalculees a
                // chaque mesure ; tirets tant qu'aucune position n'est
                // accumulee.
                Expanded(
                  flex: 116,
                  child: Container(
                    decoration: BoxDecoration(
                      border: Border.all(color: AppColors.border, width: 1.5),
                    ),
                    child: Column(
                      children: [
                        Expanded(
                          flex: 64,
                          child: Container(
                            color: AppColors.tan,
                            // Meme IntrinsicHeight que le premier tableau :
                            // sans lui, les trois filets verticaux ne suivent
                            // pas la meme hauteur que ceux du tableau du haut.
                            child: IntrinsicHeight(
                              child: Row(
                                children: [
                                  for (var i = 0; i < 3; i++) ...[
                                    if (i > 0)
                                      Container(
                                        width: 1.5,
                                        color: AppColors.border,
                                      ),
                                    Expanded(
                                      child: Container(
                                        height: double.infinity,
                                        alignment: Alignment.center,
                                        child: FittedBox(
                                          fit: BoxFit.scaleDown,
                                          child: Text(
                                            const ['Xmoy', 'Ymoy', 'Zmoy'][i],
                                            style: TextStyle(
                                              fontFamily: kSerif,
                                              fontSize:
                                                  (24 * k).clamp(13.0, 24.0),
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        ),
                        Expanded(
                          flex: 180,
                          child: Container(
                            color: Colors.white,
                            alignment: Alignment.center,
                            child: Row(
                              children: [
                                for (var i = 0; i < 3; i++) ...[
                                  if (i > 0)
                                    Container(
                                      width: 2.5,
                                      height: double.infinity,
                                      color: AppColors.ink,
                                    ),
                                  Expanded(
                                    child: FittedBox(
                                      fit: BoxFit.scaleDown,
                                      child: Padding(
                                        padding: EdgeInsets.symmetric(
                                          horizontal: 12 * k,
                                        ),
                                        child: Text(
                                          session.moyennePerle == null
                                              ? '—'
                                              : (i == 0
                                                  ? '${session.moyennePerle!.xmoy}'
                                                  : i == 1
                                                      ? '${session.moyennePerle!.ymoy}'
                                                      : '${session.moyennePerle!.zmoy}'),
                                          style: TextStyle(
                                            fontFamily: kSerif,
                                            fontSize:
                                                (72 * k).clamp(28.0, 72.0),
                                            color: AppColors.ink,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                // Envoi manuel de la file BLE vers le DT. L'envoi est deja
                // automatique des que le lien est authentifie (§16.1) : ce
                // bouton ne sert qu'a forcer une reprise apres un echec en
                // cours de route. Desactive quand le lien BLE n'est pas vert
                // ou quand la file locale est vide (rien a transmettre).
                SizedBox(height: 12 * k),
                Align(
                  alignment: Alignment.centerRight,
                  child: OutlinedButton.icon(
                    onPressed: session.etatBle == EtatCouche.connecte &&
                            session.fileAttenteBle > 0 &&
                            !session.envoiBleActif
                        ? () => session.forcerEnvoiBle()
                        : null,
                    icon: Icon(
                      Icons.upload_outlined,
                      size: (22 * k).clamp(16.0, 22.0),
                    ),
                    label: Text(
                      'Envoi manuel',
                      style: TextStyle(
                        fontFamily: kSerif,
                        fontSize: (15 * k).clamp(11.0, 15.0),
                      ),
                    ),
                    style: OutlinedButton.styleFrom(
                      padding: EdgeInsets.symmetric(
                        horizontal: 20 * k,
                        vertical: 12 * k,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

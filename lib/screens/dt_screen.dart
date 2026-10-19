import 'package:flutter/material.dart';

import '../state/session.dart';
import '../theme/app_theme.dart';
import '../theme/responsive.dart';
import '../widgets/profile_shell.dart';
import '../widgets/carte_suivi.dart';
import '../widgets/status_badges.dart';

/// Ecran du chauffeur de camion (DT).
class DtScreen extends StatelessWidget {
  const DtScreen({super.key, required this.session});

  final Session session;

  @override
  Widget build(BuildContext context) {
    return ProfileShell(
      session: session,
      body: ListenableBuilder(
        listenable: session,
        builder: (context, _) {
          // Tout est lu ici, dans le builder : une taille de fenetre ou une
          // valeur de session changee ailleurs doit etre retrouvee a ce
          // niveau, pas figee au dernier build de l'ecran.
          final MiseEnPage mise = MiseEnPage.depuis(context);

          // Marge commune aux trois ecrans profils : les blocs commencent
          // aux memes coordonnees quel que soit l'ecran.
          return Padding(
            padding: mise.margeEcran,
            // En paysage large et bas (ou en fenetre reduite), les valeurs et
            // la barre de trajet ne tiennent plus : l'ensemble defile au lieu
            // de deborder. En paysage tablette, rien a defiler et le rendu est
            // identique.
            child: LayoutBuilder(
              builder: (context, contraintes) {
                final double minHauteur =
                    (contraintes.maxHeight - mise.margeEcran.vertical)
                        .clamp(0.0, double.infinity);                return SingleChildScrollView(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(minHeight: minHauteur),
                    // `IntrinsicHeight` : le contenu reclame normalement sa
                    // hauteur naturelle, qui depasse la fenetre en portrait
                    // etroit — d'ou le debordement. En donnant une hauteur
                    // bornee, les `Expanded` internes se partagent la place
                    // disponible et les tableaux se compriment au lieu de
                    // deborder. Le `SingleChildScrollView` reste en secours
                    // pour les cas extremes, ou meme comprime ca ne suffit
                    // plus.
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxHeight: minHauteur),
                      child: IntrinsicHeight(
                        child: Column(
                          children: [
                            _TopBar(session: session),
                            SizedBox(height: 16 * mise.k),
                            Expanded(
                              // Sous 760 px de large, deux colonnes cote a cote
                              // laissent une carte illisible : la carte passe
                              // alors au dessus des valeurs.
                              child: mise.aEmpile
                                  ? Column(
                                      children: [
                                        Expanded(
                                          child: _Carte(session: session),
                                        ),
                                        SizedBox(height: 14 * mise.k),
                                        Expanded(
                                          child: _Valeurs(session: session),
                                        ),
                                      ],
                                    )
                                  : Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                        Expanded(
                                          child: _Carte(session: session),
                                        ),
                                        SizedBox(width: 20 * mise.k),
                                        Expanded(
                                          child: _Valeurs(session: session),
                                        ),
                                      ],
                                    ),
                            ),
                            SizedBox(height: 14 * mise.k),
                            _RouteBar(
                              progress: session.routeProgress,
                              fractionWaypoint:
                                  session.progression.fractionWaypoint,
                            ),
                            SizedBox(height: 6 * mise.k),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }
}

/// Carte de suivi du DT.
///
/// Elle ne montre rien tant que la base ne connait pas la position de la
/// destination : mieux vaut l'emplacement d'attente qu'une carte centree au
/// hasard.
class _Carte extends StatelessWidget {
  const _Carte({required this.session});

  final Session session;

  @override
  Widget build(BuildContext context) {
    final ({double lat, double lng})? arrivee = session.positionDestination;
    if (arrivee == null) return const MapPlaceholder();

    // Cadre de la carte : il clignote en rouge pendant l'alerte (le meme
    // `Clignotant` que le bandeau, donc la meme periode de 600 ms). Hors
    // alerte, il reste un simple cadre gris, sans aucun cout d'animation.
    // C'est la carte entiere qui est enrobee : le clignotement se voit autour
    // de la zone de suivi, pas seulement sur la banniere de texte.
    return Clignotant(
      session: session,
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(
            color: session.alerteActive ? AppColors.red : AppColors.border,
            width: 3,
          ),
        ),
        child: CarteSuivi(
          destination: session.destination,
          depart: session.positionDepart,
          arrivee: arrivee,
          position: session.positionDt,
          parcours: session.parcoursCarte,
          positionParcourue: session.parcoursParcouruCarte,
          libelleDestination: session.destination,
        ),
      ),
    );
  }
}

/// Colonne de droite : les tableaux de valeurs du DT.
///
/// Elle est partagee entre la disposition cote a cote et la disposition
/// empilee, pour ne pas ecrire deux fois les memes tableaux.
class _Valeurs extends StatelessWidget {
  const _Valeurs({required this.session});

  final Session session;

  @override
  Widget build(BuildContext context) {
    final double k = MiseEnPage.depuis(context).k;

    // Repartition en proportions (option 2) : chaque bloc recoit un `flex`
    // explicite au lieu de se partager « ce qui reste ». La hauteur des
    // tableaux ne depend donc plus de ce que consomment les bandeaux, ecarts
    // et barre de trajet — elle suit toujours la meme proportion, quelle que
    // soit la fenetre.
    //
    // Les bandeaux sont en `FlexFit.loose` : leur `flex` est un **maximum**,
    // pas une exigence. Ils prennent leur hauteur bornee si elle tient dans
    // leur part, et la cede au tableau quand la fenetre est basse. C'est ce
    // qui garantit a la fois la proportion stable et l'absence de debordement.
    //
    // Somme des flex = 25, soit : bandeau d'affectation 5/25, premier
    // tableau 10/25, second tableau 10/25. Le bandeau d'alerte n'a plus de
    // place propre : quand une alerte se declenche, elle se superpose (en
    // Stack) a la banniere d'affectation, sans deplacer les tableaux.
    return Column(
      children: [
        Flexible(
          flex: 5,
          fit: FlexFit.loose,
          child: Clignotant(
            session: session,
            child: _BanniereAffectation(session: session),
          ),
        ),
        SizedBox(height: 15 * k),
        Expanded(
          flex: 20,
          child: _ValueTable(
            headers: const ['Destination', 'Dumping Area'],
            values: [
              session.destination.isEmpty
                  ? 'En attente'
                  : session.destination,
              session.dumpingArea.isEmpty
                  ? 'En attente'
                  : session.dumpingArea,
            ],
            valueSize: 45,
          ),
        ),
        SizedBox(height: 18 * k),
        Expanded(
          flex: 20,
          child: _ValueTable(
            headers: const [
              'Easting',
              'Northing',
              'Elevation',
            ],
            // Valeurs GNSS reelles ou « — » tant qu'aucune mesure n'est
            // arrivee : un tiret honnete (acquisition en cours, GPS absent
            // ou permission refusee) plutot que des coordonnees de demarrage
            // en dur qui feraient croire a une position. Sous Chrome, le
            // service ne produit une mesure que si l'ordinateur bouge de
            // 5 m (filtre distance) : immobile, il reste sur « — ».
            values: session.derniereMesure == null
                ? const ['—', '—', '—']
                : [
                    '${session.easting}',
                    '${session.northing}',
                    '${session.elevation}',
                  ],
            valueSize: 45,
          ),
        ),
      ],
    );
  }
}

/// Bandeau d'etat de l'affectation, au dessus des deux tableaux.
///
/// D'ou viennent la destination et la dumping area : aucune des deux n'est
/// saisissable ici, elles sont choisies **et validees par le serveur**. Le
/// bandeau affiche l'horodatage de cette validation, ou signale que le
/// serveur n'a encore rien renvoye.
///
/// En alerte de trajet (detection d'ecart, options A et B), ce meme bandeau
/// bascule sur le message d'ecart : fond rouge, icone warning, texte blanc.
/// Deux sources se rejoignent dans [Session.alerteCourante] :
/// - la detection locale : le DT s'eloigne de plus de 40 m du parcours
///   vers la dumping area pendant 15 s (champ `parcours` du serveur) ;
/// - le repli serveur : champ `alerte` (geofences cote serveur).
/// L'alerte disparait des que le DT revient sur son trajet ou que le serveur
/// cesse de l'envoyer ; chaque mesure GPS pendant l'alerte rejoue le bip et
/// la vibration (voir [Session.alerter]).
class _BanniereAffectation extends StatelessWidget {
  const _BanniereAffectation({required this.session});

  final Session session;

  @override
  Widget build(BuildContext context) {
    final double k = MiseEnPage.depuis(context).k;
    final bool recue = session.affectationRecue;
    final bool alerte = session.alerteActive;
    final String messageAlerte = session.alerteCourante;
    final double police = (17 * k).clamp(12.0, 17.0);

    final double hauteur = (28 * k).clamp(18.0, 28.0);

    return Container(
      width: double.infinity,
      // Meme regle que la banniere d'affectation : hauteur bornee, une ligne.
      // En alerte, le contenu bascule sur le message d'ecart : l'alerte ne
      // reserve plus de place propre dans la colonne, elle reutilise cette
      // banniere (fond rouge, icone warning) et les tableaux ne bougent pas.
      height: hauteur,
      padding: EdgeInsets.symmetric(horizontal: 12 * k),
      decoration: BoxDecoration(
        color: alerte
            ? AppColors.red
            : recue
                ? AppColors.paper
                : AppColors.tan,
        border: Border.all(
          color: alerte
              ? AppColors.red
              : recue
                  ? AppColors.green
                  : AppColors.border,
        ),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        children: [
          Icon(
            alerte
                ? Icons.warning
                : recue
                    ? Icons.verified
                    : Icons.schedule,
            size: (20 * k).clamp(14.0, 20.0),
            color: alerte || recue ? Colors.white : const Color(0xFF6E7278),
          ),
          SizedBox(width: 8 * k),
          Expanded(
            child: Text(
              alerte
                  ? messageAlerte
                  : recue
                      ? 'Validé par le serveur · '
                          '${heureLocal(session.horodatageAffectation)}'
                      : 'Affectation en attente du serveur',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: kSerif,
                fontSize: police,
                fontWeight: FontWeight.w700,
                color: alerte ? Colors.white : AppColors.ink,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// `2026-10-08T09:00:00Z` -> `11:00:00` (heure locale du site).
  ///
  /// Une valeur non parseable s'affiche telle quelle plutot que de faire
  /// croire a une heure fausse.
  static String heureLocal(String? iso) {
    if (iso == null || iso.isEmpty) return '--:--:--';
    final DateTime? brut = DateTime.tryParse(iso);
    if (brut == null) return iso;
    final DateTime heure = brut.toLocal();
    String deux(int v) => v.toString().padLeft(2, '0');
    return '${deux(heure.hour)}:${deux(heure.minute)}:${deux(heure.second)}';
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.session});

  final Session session;

  @override
  Widget build(BuildContext context) {
    final double k = MiseEnPage.depuis(context).k;

    // Responsive : les badges ont une taille plancher (lisibilite). Sur un
    // ecran etroit (telephone portrait), leur somme depassait la largeur et
    // la barre debordait. Chaque groupe passe donc par un FittedBox
    // `scaleDown` : taille normale quand ca tient, reduit sinon — jamais de
    // debordement.
    // Barre a quatre badges d'etat : 4G a gauche du nom, puis BLE, Wi-Fi
    // (hotspot) et GPS a droite. Chaque badge passe par `_BadgeAdaptatif` :
    // sa boite garde sa proportion au lieu d'etre rognee par un FittedBox,
    // qui coupait le libelle et faisait deborder la barre.
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // Reseau externe (vers le serveur) : la 4G.
        Flexible(
          flex: 1,
          child: _BadgeAdaptatif(
            alignement: Alignment.centerLeft,
            child: GsmStatusBadge(etat: session.etat4GAffiche),
          ),
        ),
        Expanded(
          flex: 2,
          child: Center(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                // Nom de l'equipement (ou titre du profil tant qu'il n'est
                // pas connu).
                session.deviceName.isEmpty
                    ? (session.profile?.titre ?? 'DT')
                    : session.deviceName,
                maxLines: 1,
                style: TextStyle(
                  fontFamily: kSerif,
                  fontSize: (54 * k).clamp(24.0, 54.0),
                  color: AppColors.ink,
                ),
              ),
            ),
          ),
        ),
        // Liens P2P et capteurs a droite du nom : BLE (voyant bluetooth,
        // excavatrices), Wi-Fi hotspot (voyant wifi, spotters) puis GPS
        // externe USB-C. TAB 2 est aussi la passerelle BLE et le point
        // d'acces Wi-Fi (CDC §6) : les deux badges sont presents en
        // permanence, rouge des que la couche n'est pas demarree.
        Flexible(
          flex: 3,
          child: _BadgeAdaptatif(
            alignement: Alignment.centerRight,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Test direct de la voix off : deverrouille l'audio du
                // navigateur web (autoplay policy) puis fait parler le TTS.
                // Utile des l'arrivee sur l'ecran, sans attendre une alerte.
                IconButton(
                  tooltip: 'Tester la voix off',
                  icon: Icon(
                    Icons.volume_up,
                    size: 26 * k,
                    color: AppColors.ink,
                  ),
                  onPressed: () async {
                    session.alerter.deverrouillerAudioWeb();
                    await session.alerter
                        .dire('Test de la voix off, alerte trajet operationnelle');
                  },
                ),
                SizedBox(width: 6 * k),
                BleStatusBadge(
                  etat: session.etatBleAffiche,
                  nombreClients: session.liensBle,
                ),
                SizedBox(width: 10 * k),
                WifiP2pStatusBadge(
                  etat: session.etatWifiAffiche,
                  nombreClients: session.liensWifi,
                ),
                SizedBox(width: 10 * k),
                GpsStatusBadge(etat: session.etatGpsAffiche),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Boite un badge (ou un groupe de badges) en le mettant a l'echelle de la
/// place disponible **dans les deux sens**.
///
/// Un `FittedBox` seul se contente de rogner le dessin : la boite gardait sa
/// hauteur, le libelle etait coupe et la barre du haut debordait. Ici le
/// facteur d'echelle est calcule, puis applique aux deux dimensions — le
/// badge devient plus petit mais reste entier et lisible.
class _BadgeAdaptatif extends StatelessWidget {
  const _BadgeAdaptatif({required this.child, required this.alignement});

  final Widget child;
  final Alignment alignement;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: alignement,
      // Le badge garde sa taille naturelle (aucune contrainte infinie, donc
      // aucun plantage au layout) ; s'il ne rentre pas dans la place laissee
      // par la ligne, il est reduit d'autant, entier et lisible.
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: alignement,
        child: child,
      ),
    );
  }
}

/// Tableau a bandeau tan (Destination / ENE).
///
/// Le tableau n'a pas de hauteur propre : il se remplit de la place que la
/// colonne lui donne (l'en-tete garde la proportion 56 / 186 de la
/// reference). Les polices suivent le coefficient de mise en page et les
/// valeurs passent par un `FittedBox` pour ne jamais deborder d'une cellule.
class _ValueTable extends StatelessWidget {
  const _ValueTable({
    required this.headers,
    required this.values,
    required this.valueSize,
  });

  final List<String> headers;
  final List<String> values;

  /// Police de reference de la valeur, en 1440 x 900.
  final double valueSize;

  @override
  Widget build(BuildContext context) {
    final double k = MiseEnPage.depuis(context).k;
    final double policeEntete = (19 * k).clamp(13.0, 19.0);
    final double policeValeur = (valueSize * k).clamp(18.0, valueSize);

    // Le tableau prend toute la hauteur qu'on lui donne et la repartit entre
    // l'en-tete et les valeurs dans la meme proportion qu'en reference
    // (56 / 130) : rien n'est fige, donc rien ne deborde.
    //
    // Pas d'`IntrinsicHeight` dans l'en-tete : il exige une hauteur que le
    // parent en `Expanded` ne peut pas fournir, et l'en-tete finissait plus
    // haut que sa part, faisant deborder la colonne.
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.border, width: 1.5),
      ),
      child: Column(
        children: [
          Expanded(
            flex: 56,
            child: Container(
              color: AppColors.tan,
              child: Row(
                children: [
                  for (var i = 0; i < headers.length; i++) ...[
                    if (i > 0) Container(width: 1.5, color: AppColors.border),
                    Expanded(
                      child: Container(
                        height: double.infinity,
                        alignment: Alignment.center,
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            headers[i],
                            style: TextStyle(
                              fontFamily: kSerif,
                              fontSize: policeEntete,
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
          Expanded(
            flex: 100,
            child: Container(
              color: Colors.white,
              // Pas d'`IntrinsicHeight` : les cellules sont toutes en
              // `height: double.infinity`, elles se remplissent d'elles-memes
              // de la hauteur donnee et le FittedBox redimensionne le texte.
              child: Row(
                children: [
                  for (var i = 0; i < values.length; i++) ...[
                    if (i > 0)
                      Container(width: 2.5, color: AppColors.ink),
                    Expanded(
                      child: Container(
                        height: double.infinity,
                        alignment: Alignment.center,
                        padding: EdgeInsets.symmetric(horizontal: 4 * k),
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            values[i],
                            style: TextStyle(
                              fontFamily: kSerif,
                              fontSize: policeValeur,
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
    );
  }
}

/// Barre de progression du trajet (depart, prochain waypoint, position, fin).
///
/// Le waypoint affiche est le **prochain sommet non franchi de la polyline
/// recue du serveur** (CDC §4.6), a sa fraction reelle de la longueur du
/// parcours — pas un repère fige. Sans parcours chargé, aucun waypoint
/// intermediaire n'est dessine.
class _RouteBar extends StatelessWidget {
  const _RouteBar({required this.progress, this.fractionWaypoint});

  final double progress;

  /// Fraction de longueur du prochain waypoint (0..1), ou null sans
  /// parcours : la barre n'affiche alors que depart/arrivee/position.
  final double? fractionWaypoint;

  @override
  Widget build(BuildContext context) {
    final double k = MiseEnPage.depuis(context).k;
    // Barre plus visible : 26 px sur la tablette (contre 6 px auparavant,
    // jugee trop petite a l'usage). Les repères restent lisibles au Doigt.
    final double hauteur = (10 * k).clamp(15.0, 30.0);
    final double epaisseur = (6 * k).clamp(3.0, 25.0);
    final double trait = (55 * k).clamp(0.5, 1.5);
    // Les cercles ne doivent jamais depasser la hauteur : sinon ils sont
    // rognes par le bord de la barre. On borne donc chaque cote a la hauteur
    // disponible.
    final double coteBornes = (20 * k).clamp(10.0, hauteur);
    final double coteRepere = (14 * k).clamp(8.0, hauteur);
    final double cotePosition = (24 * k).clamp(12.0, hauteur);

    return SizedBox(
      height: hauteur,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final double width = constraints.maxWidth;
          const double start = 0.03;
          const double end = 0.97;
          final double span = end - start;
          final double current = start + span * progress.clamp(0.0, 1.0);
          final double? fractionWp = fractionWaypoint;
          final double wp = fractionWp == null
              ? -1
              : start + span * fractionWp.clamp(0.0, 1.0);
          final double axe = hauteur / 2;

          Widget point(double position, double cote, Widget enfant) =>
              Positioned(
                left: width * position - cote / 2,
                top: axe - cote / 2,
                child: SizedBox(width: cote, height: cote, child: enfant),
              );

          return Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                left: width * start,
                right: width * (1 - end),
                top: axe - epaisseur / 2,
                height: epaisseur,
                child: Container(color: Colors.black),
              ),
              Positioned(
                left: width * start,
                width: width * (current - start),
                top: axe - epaisseur / 2,
                height: epaisseur,
                child: Container(color: AppColors.green),
              ),
              point(
                start,
                coteBornes,
                Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white,
                    border: Border.fromBorderSide(
                      BorderSide(color: Colors.black, width: trait),
                    ),
                  ),
                ),
              ),
              point(
                end,
                coteBornes,
                Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white,
                    border: Border.fromBorderSide(
                      BorderSide(color: Colors.black, width: trait),
                    ),
                  ),
                ),
              ),
              if (wp >= 0)
                point(
                  wp,
                  coteRepere,
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Color(0xFFB9BBBD),
                    ),
                  ),
                ),
              point(
                current,
                cotePosition,
                Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white,
                    border: Border.fromBorderSide(
                      BorderSide(color: Colors.black, width: trait),
                    ),
                  ),
                  child: Icon(
                    Icons.navigation,
                    size: (18 * k).clamp(12.0, 18.0),
                    color: AppColors.ink,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

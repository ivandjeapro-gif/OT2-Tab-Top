import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/transmetteur.dart';
import '../models/models.dart';
import '../state/session.dart';
import '../theme/app_theme.dart';
import '../theme/responsive.dart';

/// Ecrans de **relecture** du profil spotter (rapport du 14/10 §1.2, points
/// 1 a 3) :
///
/// - [ouvrirVisionneusePhotos] : relecture des captures (Picture) avec
///   filtrage — toutes / avec photo / sans photo — sur le blast entier ;
/// - [ouvrirHistorique] : relecture de l'historique — journal technique
///   persiste (`journal`) et notifications Boss recues — deux onglets ;
/// - [ouvrirCompteRendu] : synthese de fin de mission (blocs verrouilles,
///   lignes envoyees, photos manquantes) copiable dans le presse-papiers.
///
/// Les trois panneaux sont des lectures de la base locale : rien n'y est
/// modifiable, la seule ecriture possible est la copie du compte-rendu.
///
/// Entrée unique par `showModalBottomSheet` (meme gabarit que
/// [SupervisionReseau]) : cohérence d'usage avec la supervision reseau.

// ============================================================================
//  1. Visionneuse des captures (Picture) avec filtrage
// ============================================================================

/// Ouvre la visionneuse des photos du spotter, sur le blast courant.
///
/// Le perimetre est le **blast entier** (tous ses blocs) : une photo oubliee
/// dans un bloc deja quitte doit rester retrouvable. Filtres proposes :
/// `Toutes`, `Avec photo`, `Sans photo` — ce dernier etant celui qui sert
/// avant le verrouillage (reprendre les lignes oubliees).
void ouvrirVisionneusePhotos(BuildContext context, Session session) {
  _ouvrirFeuille(
    context,
    session,
    titre: 'Captures (Picture)',
    enfant: _VisionneusePhotos(session: session),
  );
}

class _VisionneusePhotos extends StatefulWidget {
  const _VisionneusePhotos({required this.session});

  final Session session;

  @override
  State<_VisionneusePhotos> createState() => _VisionneusePhotosState();
}

enum _FiltrePhotos { toutes, avec, sans }

class _VisionneusePhotosState extends State<_VisionneusePhotos> {
  _FiltrePhotos _filtre = _FiltrePhotos.toutes;

  Session get session => widget.session;

  List<({Blast blast, BlocTravail bloc, LigneBlast ligne})> get _entrees {
    final Blast? blast = session.blast;
    if (blast == null) {
      return <({Blast blast, BlocTravail bloc, LigneBlast ligne})>[];
    }
    final List<({Blast blast, BlocTravail bloc, LigneBlast ligne})> liste =
        <({Blast blast, BlocTravail bloc, LigneBlast ligne})>[];
    for (final BlocTravail bloc in blast.blocs) {
      for (final LigneBlast ligne in bloc.lignes) {
        liste.add((blast: blast, bloc: bloc, ligne: ligne));
      }
    }
    return liste;
  }

  @override
  Widget build(BuildContext context) {
    final double k = MiseEnPage.depuis(context).k;
    final List<({Blast blast, BlocTravail bloc, LigneBlast ligne})> toutes =
        _entrees;
    final List<({Blast blast, BlocTravail bloc, LigneBlast ligne})> filtrees =
        toutes
            .where(
              (e) => switch (_filtre) {
                _FiltrePhotos.avec => e.ligne.hasPicture,
                _FiltrePhotos.sans => !e.ligne.hasPicture,
                _FiltrePhotos.toutes => true,
              },
            )
            .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Filtres : compteurs affiches, pour savoir avant d'ouvrir s'il reste
        // du travail (lignes sans picture).
        Wrap(
          spacing: 8 * k,
          children: [
            for (final (_FiltrePhotos f, String libelle) in [
              (_FiltrePhotos.toutes, 'Toutes (${toutes.length})'),
              (
                _FiltrePhotos.avec,
                'Avec photo (${toutes.where((e) => e.ligne.hasPicture).length})'
              ),
              (
                _FiltrePhotos.sans,
                'Sans photo (${toutes.where((e) => !e.ligne.hasPicture).length})'
              ),
            ])
              ChoiceChip(
                label: Text(libelle),
                selected: _filtre == f,
                onSelected: (_) => setState(() => _filtre = f),
                selectedColor: AppColors.tan,
                labelStyle: TextStyle(
                  fontSize: (13 * k).clamp(11.0, 13.0),
                  color: AppColors.ink,
                ),
              ),
          ],
        ),
        SizedBox(height: 10 * k),
        Expanded(
          child: filtrees.isEmpty
              ? Center(
                  child: Text(
                    'Aucune ligne dans ce filtre',
                    style: TextStyle(
                      fontFamily: kSerif,
                      fontSize: (15 * k).clamp(12.0, 15.0),
                      color: AppColors.greyText,
                    ),
                  ),
                )
              : GridView.builder(
                  padding: EdgeInsets.zero,
                  gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 190,
                    mainAxisSpacing: 10 * k,
                    crossAxisSpacing: 10 * k,
                    childAspectRatio: 0.72,
                  ),
                  itemCount: filtrees.length,
                  itemBuilder: (context, i) => _CartePhoto(
                    entree: filtrees[i],
                    k: k,
                    onOuvrir: () => _voirPhoto(context, filtrees[i]),
                  ),
                ),
        ),
      ],
    );
  }
}

/// Affiche la photo d'une ligne en grand (meme principe que le dialogue de
/// la colonne Picture du tableau du spotter).
void _voirPhoto(
  BuildContext context,
  ({Blast blast, BlocTravail bloc, LigneBlast ligne}) entree,
) {
  final Uint8List? octets = entree.ligne.photo;
  showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(
        'Photo ${entree.ligne.idDt} - blast ${entree.blast.numero}, '
        'bloc ${entree.bloc.numero}',
      ),
      content: octets == null
          ? const SizedBox(
              width: 280,
              child: Text(
                'Aucune image enregistree sur ce poste pour cette ligne.',
                style: TextStyle(fontSize: 15, color: AppColors.slate),
              ),
            )
          : InteractiveViewer(
              maxScale: 6,
              child: Image.memory(
                octets,
                width: 360,
                fit: BoxFit.contain,
                gaplessPlayback: true,
                errorBuilder: (_, __, ___) => const Text(
                  'Image illisible.',
                  style: TextStyle(color: AppColors.slate),
                ),
              ),
            ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Fermer'),
        ),
      ],
    ),
  );
}

/// Tuile d'une ligne : vignette de la photo (ou placeholder), contexte
/// blast/bloc/DT, commentaire. Un tap ouvre la photo en grand.
class _CartePhoto extends StatelessWidget {
  const _CartePhoto({
    required this.entree,
    required this.k,
    required this.onOuvrir,
  });

  final ({Blast blast, BlocTravail bloc, LigneBlast ligne}) entree;
  final double k;
  final VoidCallback onOuvrir;

  @override
  Widget build(BuildContext context) {
    final LigneBlast ligne = entree.ligne;
    final Uint8List? octets = ligne.photo;

    return InkWell(
      onTap: onOuvrir,
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(color: AppColors.border, width: 1.5),
          color: Colors.white,
        ),
        padding: EdgeInsets.all(8 * k),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: octets == null
                  ? Container(
                      color: AppColors.greyBg,
                      alignment: Alignment.center,
                      child: Icon(
                        Icons.add_a_photo_outlined,
                        size: 28 * k,
                        color: ligne.hasPicture
                            ? AppColors.greyText
                            : AppColors.border,
                      ),
                    )
                  : Image.memory(
                      octets,
                      fit: BoxFit.cover,
                      gaplessPlayback: true,
                      errorBuilder: (_, __, ___) => Container(
                        color: AppColors.greyBg,
                        alignment: Alignment.center,
                        child: const Icon(Icons.broken_image, size: 24),
                      ),
                    ),
            ),
            SizedBox(height: 6 * k),
            Text(
              'Blast ${entree.blast.numero} - Bloc ${entree.bloc.numero}'
              '${entree.bloc.verrouille ? ' (verrouille)' : ''}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: (11 * k).clamp(9.0, 11.0),
                color: AppColors.slate,
              ),
            ),
            Text(
              'DT ${ligne.dt} n${ligne.idDt} - ${ligne.time}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: kSerif,
                fontSize: (13 * k).clamp(11.0, 13.0),
                color: AppColors.ink,
              ),
            ),
            if (ligne.comment.isNotEmpty)
              Text(
                ligne.comment,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: (11 * k).clamp(9.0, 11.0),
                  color: AppColors.greyText,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
//  2. Historique des evenements (journal persiste + notifications Boss)
// ============================================================================

/// Ouvre l'historique : journal des ecritures acceptees (persiste en base,
/// donc relecture possible apres redemarrage) et notifications Boss recues.
void ouvrirHistorique(BuildContext context, Session session) {
  _ouvrirFeuille(
    context,
    session,
    titre: 'Historique',
    enfant: _Historique(session: session),
  );
}

class _Historique extends StatelessWidget {
  const _Historique({required this.session});

  final Session session;

  @override
  Widget build(BuildContext context) {
    final double k = MiseEnPage.depuis(context).k;

    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final List<String> journal = session.base.journal;
        final List<NotificationServeur> notifs = session.base.notifications(
          session.profile?.code ?? '',
        );
        return DefaultTabController(
      length: 2,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TabBar(
            labelColor: AppColors.ink,
            unselectedLabelColor: AppColors.greyText,
            indicatorColor: AppColors.tan,
            labelStyle: TextStyle(
              fontFamily: kSerif,
              fontSize: (15 * k).clamp(12.0, 15.0),
            ),
            tabs: [
              Tab(text: 'Journal (${journal.length})'),
              Tab(text: 'Notifications Boss (${notifs.length})'),
            ],
          ),
          Expanded(
            child: TabBarView(
                children: [
                _ListeTexte(
                  vides: journal,
                  vide: 'Aucune ecriture journalisee',
                  k: k,
                ),
                notifs.isEmpty
                    ? Center(
                        child: Text(
                          'Aucune notification Boss recue',
                          style: TextStyle(
                            fontFamily: kSerif,
                            fontSize: (14 * k).clamp(11.0, 14.0),
                            color: AppColors.greyText,
                          ),
                        ),
                      )
                    : ListView.separated(
                        padding: EdgeInsets.all(8 * k),
                        itemCount: notifs.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (context, i) {
                          final NotificationServeur n = notifs[i];
                          return Padding(
                            padding: EdgeInsets.symmetric(vertical: 6 * k),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Numero ${n.id}'
                                  '${n.profil.isEmpty ? '' : ' - ${n.profil}'}'
                                  '${n.horodatage.isEmpty ? '' : ' - ${n.horodatage}'}',
                                  style: TextStyle(
                                    fontSize: (11 * k).clamp(9.0, 11.0),
                                    color: AppColors.greyText,
                                  ),
                                ),
                                Text(
                                  n.message,
                                  style: TextStyle(
                                    fontFamily: kSerif,
                                    fontSize: (14 * k).clamp(11.0, 14.0),
                                    color: AppColors.ink,
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
              ],
            ),
          ),
        ],
      ),
        );
      },
    );
  }
}

/// Liste horodatee du journal technique (lecture pure de `BaseLocale.journal`).
class _ListeTexte extends StatelessWidget {
  const _ListeTexte({required this.vides, required this.vide, required this.k});

  final List<String> vides;
  final String vide;
  final double k;

  @override
  Widget build(BuildContext context) {
    if (vides.isEmpty) {
      return Center(
        child: Text(
          vide,
          style: TextStyle(
            fontFamily: kSerif,
            fontSize: (14 * k).clamp(11.0, 14.0),
            color: AppColors.greyText,
          ),
        ),
      );
    }
    return Container(
      color: Colors.white,
      child: ListView.builder(
        padding: EdgeInsets.all(8 * k),
        itemCount: vides.length,
        itemBuilder: (context, i) => Padding(
          padding: EdgeInsets.symmetric(vertical: 2 * k),
          child: Text(
            vides[i],
            style: TextStyle(
              fontFamily: kSans,
              fontSize: (12 * k).clamp(10.0, 12.0),
              color: AppColors.ink,
            ),
          ),
        ),
      ),
    );
  }
}

// ============================================================================
//  3. Compte-rendu de mission
// ============================================================================

/// Ouvre le compte-rendu de fin de mission : synthese generee depuis la base
/// (blocs verrouilles, lignes envoyees, photos manquantes) et copiable en
/// presse-papiers pour collage dans un courriel / canal du bureau.
void ouvrirCompteRendu(BuildContext context, Session session) {
  final String texte = _genererCompteRendu(session);
  showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Compte-rendu de mission'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Text(
            texte,
            style: const TextStyle(
              fontFamily: kSans,
              fontSize: 13,
              height: 1.4,
              color: AppColors.ink,
            ),
          ),
        ),
      ),
      actions: [
        TextButton.icon(
          onPressed: () {
            Clipboard.setData(ClipboardData(text: texte));
            session.push('Compte-rendu copie dans le presse-papiers');
            Navigator.of(context).pop();
          },
          icon: const Icon(Icons.copy, size: 18),
          label: const Text('Copier'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Fermer'),
        ),
      ],
    ),
  );
}

/// Genere le texte du compte-rendu depuis la base locale.
///
/// Lecture pure : rien n'est marque "transmis" ici — le rapport ne fait
/// que constater (verrouillage, envoi deja poses par les ecritures metier).
String _genererCompteRendu(Session session) {
  final StringBuffer sb = StringBuffer();
  final DateTime now = DateTime.now();
  String deux(int v) => v.toString().padLeft(2, '0');
  final String date =
      '${deux(now.day)}/${deux(now.month)}/${now.year} '
      '${deux(now.hour)}:${deux(now.minute)}';

  sb.writeln('COMPTE-RENDU DE MISSION - SPOTTER');
  sb.writeln('Genere le $date (appareil : '
      '${session.deviceName.isEmpty ? session.deviceId : session.deviceName})');
  sb.writeln();

  int totalLignes = 0;
  int totalSansPhoto = 0;
  int totalVerrouilles = 0;

  if (session.base.blasts.isEmpty) {
    sb.writeln('Aucun blast en base locale.');
  }
  for (final Blast blast in session.base.blasts) {
    final int lignes = blast.nombreLignes;
    final int sansPhoto = blast.blocs.fold<int>(
      0,
      (int t, BlocTravail b) =>
          t + b.lignes.where((LigneBlast l) => !l.hasPicture).length,
    );
    final int verrouilles =
        blast.blocs.where((BlocTravail b) => b.verrouille).length;
    final int lignesVerrouillees = blast.blocs
        .where((BlocTravail b) => b.verrouille)
        .fold<int>(0, (int total, BlocTravail b) => total + b.nombreLignes);
    final int sansPhotoVerrouillees = blast.blocs
        .where((BlocTravail b) => b.verrouille)
        .fold<int>(
          0,
          (int total, BlocTravail b) => total +
              b.lignes.where((LigneBlast l) => !l.hasPicture).length,
        );
    totalLignes += lignes;
    totalSansPhoto += sansPhoto;
    totalVerrouilles += verrouilles;

    sb.writeln('BLAST ${blast.numero} (carte ${blast.carte})');
    sb.writeln('  Statut envoye : ${blast.envoye ? 'OUI' : 'NON'}');
    sb.writeln('  Blocs : ${blast.nombreBlocs} '
        '($verrouilles verrouille(s)) - Lignes : $lignes - '
        'Sans photo : $sansPhoto');
    sb.writeln('  Perimetre verrouille : $lignesVerrouillees ligne(s), '
        '$sansPhotoVerrouillees sans photo.');
    for (final BlocTravail bloc in blast.blocs) {
      if (bloc.nombreLignes == 0 && !bloc.verrouille) continue;
      sb.writeln('    Bloc ${bloc.numero} : '
          '${bloc.nombreLignes} ligne(s), '
          '${bloc.verrouille ? 'verrouille' : 'ouvert'}, '
          '${bloc.lignes.where((LigneBlast l) => !l.hasPicture).length} '
          'sans photo');
    }
    sb.writeln();
  }

  sb.writeln('TOTAL : $totalLignes ligne(s) sur '
      '${session.base.blasts.length} blast(s), $totalVerrouilles bloc(s) '
      'verrouille(s), $totalSansPhoto ligne(s) sans photo.');
  final int enAttente = session.enAttente;
  sb.writeln('File de synchronisation serveur : $enAttente evenement(s) '
      'en attente${enAttente == 0 ? ' (tout est parti)' : ''}.');
  return sb.toString();
}

// ============================================================================
//  Gabarit commun (feuille modale)
// ============================================================================

void _ouvrirFeuille(
  BuildContext context,
  Session session, {
  required String titre,
  required Widget enfant,
}) {
  showModalBottomSheet<void>(
    context: context,
    backgroundColor: AppColors.paper,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(8)),
    ),
    builder: (_) => SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.78,
      child: _Feuille(session: session, titre: titre, enfant: enfant),
    ),
  );
}

/// Enveloppe des panneaux de relecture : garde la session accessible aux
/// enfants via `findAncestorStateOfType` (la feuille vit hors de l'arbre de
/// l'ecran spotter, les LectureBuilder ne passent pas la frontiere du sheet).
class _Feuille extends StatefulWidget {
  const _Feuille({
    required this.session,
    required this.titre,
    required this.enfant,
  });

  final Session session;
  final String titre;
  final Widget enfant;

  @override
  State<_Feuille> createState() => _FeuilleState();
}

class _FeuilleState extends State<_Feuille> {
  @override
  Widget build(BuildContext context) {
    final double k = MiseEnPage.depuis(context).k;
    return Padding(
      padding: EdgeInsets.all(16 * k),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.titre == 'Captures (Picture)')
            Padding(
              padding: EdgeInsets.only(bottom: 6 * k),
              child: Text(
                'Blast ${widget.session.blastCourant.isEmpty ? '—' : widget.session.blastCourant} · Bloc ${widget.session.blocCourant.isEmpty ? '—' : widget.session.blocCourant}',
                style: TextStyle(
                  fontFamily: kSerif,
                  fontSize: (13 * k).clamp(11.0, 13.0),
                  color: AppColors.slate,
                ),
              ),
            ),
          Row(
            children: [
              Expanded(
                child: Text(
                  widget.titre,
                  style: TextStyle(
                    fontFamily: kSerif,
                    fontSize: (24 * k).clamp(18.0, 24.0),
                    fontWeight: FontWeight.w700,
                    color: AppColors.ink,
                  ),
                ),
              ),
              IconButton(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
          SizedBox(height: 8 * k),
          Expanded(child: widget.enfant),
        ],
      ),
    );
  }
}

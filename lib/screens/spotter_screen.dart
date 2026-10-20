import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';

import '../communication/permissions_photo.dart';
import '../data/base_locale.dart';
import '../models/models.dart';
import '../state/session.dart';
import '../theme/app_theme.dart';
import '../theme/responsive.dart';
import '../widgets/profile_shell.dart';
import '../widgets/voyants_entete.dart';
import 'spotter_relire.dart';

/// Ecran du spotter geologique.
///
/// La selection vit dans la session : un blast, puis un bloc de ce blast.
/// Toutes les lignes du tableau et toutes les lignes ajoutees par le bouton
/// `+` appartiennent au bloc selectionne, et la carte vient de ce bloc.
///
/// `Lock` valide le **bloc courant** (paire blast/bloc) : les lignes deja
/// saisies dans ce bloc sont comptees, il est ferme et le bouton `+` devient
/// inactif pour lui — les autres blocs du blast restent ouverts. `Envoyer`
/// transmet ensuite selon le mode parametre (`meta.envoi_mode`) : le blast
/// entier, le bloc courant ou les seuls blocs verrouilles. Changer de bloc ou
/// de blast reste toujours possible, meme sur un bloc verrouille.
class SpotterScreen extends StatefulWidget {
  const SpotterScreen({super.key, required this.session});

  final Session session;

  @override
  State<SpotterScreen> createState() => _SpotterScreenState();
}

class _SpotterScreenState extends State<SpotterScreen> {
  Session get session => widget.session;

  Blast? get _blast => session.blast;
  BlocTravail? get _bloc => session.bloc;
  bool get _verrouille => session.verrouille;

  List<LigneBlast> get _lignes => _bloc?.lignes ?? const <LigneBlast>[];

  /// Nombre de lignes saisies sur le blast entier, et pas seulement sur le
  /// bloc affiche : c'est ce que compte le verrouillage.
  int get _lignesDuBlast {
    final Blast? blast = _blast;
    if (blast == null) return 0;
    return blast.blocs.fold<int>(0, (total, b) => total + b.nombreLignes);
  }

/// Ajoute une ligne dans le bloc selectionne.
  ///
  /// Le blast, le bloc et la carte ne sont pas saisissables : ils viennent de
  /// la selection courante, donc une ligne ne peut pas partir dans un autre
  /// bloc par erreur.
  ///
  /// DT et Id DT sont deux listes liees, lues dans la base : on choisit
  /// d'abord la famille de DT (DT 1500, DT 785...), puis un DT dans le lot de
  /// cette famille. Les identifiants etant non redondants sur tout le parc,
  /// le second menu ne propose jamais le meme numero ailleurs.
  Future<void> _addRecord() async {
    // Double-tap : deux dialogues empiles ecriraient deux fois la meme ligne.
    if (_formulaireOuvert) return;

    final Blast? blast = _blast;
    final BlocTravail? bloc = _bloc;
    if (blast == null || bloc == null || bloc.verrouille) return;

    // Referentiels absents : `typesDT.first` jetterait une exception sur une
    // liste vide. On informe plutot que de laisser l'ecran planter.
    if (session.base.typesDT.isEmpty) {
      session.push(
        'Aucune famille de DT enregistree - lancez Actualiser',
      );
      return;
    }

    _formulaireOuvert = true;
    try {
      await _afficherFormulaireLigne(blast, bloc);
    } finally {
      _formulaireOuvert = false;
    }
  }

  /// Garde anti double-tap sur le bouton `+`.
  bool _formulaireOuvert = false;

  Future<void> _afficherFormulaireLigne(
    Blast blast,
    BlocTravail bloc,
  ) async {
    final TextEditingController comment = TextEditingController();
    // Message d'erreur du formulaire : affiche DANS le dialogue, jamais en
    // fermant, sinon la photo prise et le commentaire tape seraient perdus.
    String? erreur;

    // La photo n'est pas un drapeau : c'est un bouton qui ouvre l'appareil
    // photo et y depose les octets de l'image prise.
    Uint8List? photo;

    // Le type est choisi en premier, puis le numero dans le lot de ce type :
    // les deux listes sont liees, pas independantes.
    String typeChoisi = session.base.typesDT.first.code;
    String? idDtChoisi;

    final bool? saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setStateDialog) {
          final TypeDT? famille = session.base.typeDT(typeChoisi);

          Future<void> capturer(ImageSource source) async {
            // Permissions runtime a chaud (point 4 du reste-a-faire) : la
            // demande ne part qu'au tap sur la source choisie, pas a
            // l'installation. Un refus est annonce, la saisie reste ouverte.
            final bool autorise = source == ImageSource.camera
                ? await PermissionsPhoto.camera()
                : await PermissionsPhoto.galerie();
            if (!autorise) {
              if (!context.mounted) return;
              final bool definitive = await PermissionsPhoto.refuseDefinitivement(
                source == ImageSource.camera
                    ? Permission.camera
                    : Permission.photos,
              );
              if (!context.mounted) return;
              session.push(
                definitive
                    ? 'Permission ${source == ImageSource.camera ? "camera" : "galerie"} refusee definitivement : accordez-la dans les reglages systeme'
                    : 'Permission ${source == ImageSource.camera ? "camera" : "galerie"} refusee - la photo n\'a pas ete prise',
              );
              return;
            }
            final ImagePicker picker = ImagePicker();
            XFile? capture;
            try {
              // Resolution et qualite volontairement basses : la photo sert
              // de preuve sur une ligne de tir, pas d'archive. A 1600 px / 85
              // la tablette passait plusieurs secondes a recompresser apres
              // la prise de vue (d'ou la latence ressentie avant l'affichage
              // de la vignette). 1024 px / 70 reste lisible une fois zoome
              // et divise le temps de traitement par trois environ.
              capture = await picker.pickImage(
                source: source,
                maxWidth: 1024,
                imageQuality: 70,
              );
            } catch (e) {
              if (!context.mounted) return;
              session.push(
                source == ImageSource.camera
                    ? 'Appareil photo indisponible : $e - choisissez plutot '
                        'une image dans la galerie'
                    : 'Galerie indisponible : $e',
              );
              return;
            }

            // capture null = l'utilisateur a abandonne : on ne force rien.
            if (capture == null || !context.mounted) return;
            try {
              final Uint8List octets = await capture.readAsBytes();
              // La lecture est asynchrone : le dialogue a pu fermer entre
              // temps, et un setState sur un StatefulBuilder defunt casserait
              // le moteur.
              if (!context.mounted) return;
              setStateDialog(() => photo = octets);
            } catch (e) {
              if (!context.mounted) return;
              session.push('Photo illisible : $e');
            }
          }

          // Le bouton n'impose rien : on demande d'abord ou la photo vient,
          // puis on ouvre la source demandee.
          Future<void> choisirPhoto() async {
            final ImageSource? source = await showDialog<ImageSource>(
              context: context,
              builder: (context) => SimpleDialog(
                title: const Text('Picture'),
                children: [
                  SimpleDialogOption(
                    onPressed: () =>
                        Navigator.pop(context, ImageSource.camera),
                    child: const Row(
                      children: [
                        Icon(
                          Icons.photo_camera,
                          size: 26,
                          color: AppColors.green,
                        ),
                        SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Appareil photo',
                                style: TextStyle(
                                  fontFamily: kSerif,
                                  fontSize: 16,
                                  color: AppColors.ink,
                                ),
                              ),
                              Text(
                                'Prendre une photo maintenant',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: AppColors.greyText,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  SimpleDialogOption(
                    onPressed: () =>
                        Navigator.pop(context, ImageSource.gallery),
                    child: const Row(
                      children: [
                        Icon(
                          Icons.photo_library_outlined,
                          size: 26,
                          color: AppColors.green,
                        ),
                        SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Galerie',
                                style: TextStyle(
                                  fontFamily: kSerif,
                                  fontSize: 16,
                                  color: AppColors.ink,
                                ),
                              ),
                              Text(
                                'Choisir une image dans les dossiers '
                                    'du telephone',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: AppColors.greyText,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );

            // Fermeture sans choix : on ne force rien.
            if (source == null || !context.mounted) return;
            await capturer(source);
          }

          return AlertDialog(
          title: const Text('Nouvelle ligne'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Rappel non modifiable du contexte : la ligne rejoint le bloc
                // actuellement affiché, pas un bloc choisi dans le formulaire.
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.greyBg,
                    border: Border.all(color: AppColors.border),
                  ),
                  // `blast.carte` est la PREMIERE carte du blast ; sur un
                  // blast multi-RL la ligne appartient au RL selectionne.
                  child: Text(
                    'Blast ${blast.numero}   Bloc ${bloc.numero}   '
                    'Carte ${session.carteCourante.isNotEmpty ? session.carteCourante : blast.carte}',
                    style: TextStyle(
                      fontFamily: kSerif,
                      fontSize: (13 * MiseEnPage.depuis(context).k).clamp(10.0, 13.0),
                      color: AppColors.ink,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                // Referentiels absents : sans famille de DT le formulaire ne
                // peut rien produire. On le dit au lieu d'afficher un menu
                // vide que l'utilisateur prendrait pour un bug.
                if (session.base.typesDT.isEmpty)...[
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppColors.greyBg,
                      border: Border.all(color: AppColors.border),
                    ),
                    child: Text(
                      'Aucune famille de DT enregistree.\n'
                      'Fermez ce formulaire puis lancez Actualiser sur l ecran '
                      'de connexion.',
                      style: TextStyle(
                        fontFamily: kSerif,
                        fontSize:
                            (13 * MiseEnPage.depuis(context).k).clamp(10.0, 13.0),
                        color: AppColors.slate,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
                // Liste 1 : la famille de DT (DT 1500, DT 785, DT 1000...).
                // Une vraie liste deroulante : on clique, elle s'ouvre, on
                // choisit. Le menu affiche le nombre de DT de chaque famille.
                DropdownButtonFormField<String>(
                  initialValue: typeChoisi,
                  isExpanded: true,
                  style: TextStyle(
                    fontFamily: kSerif,
                    fontSize: (14 * MiseEnPage.depuis(context).k).clamp(10.0, 14.0),
                    color: AppColors.ink,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'DT',
                    labelStyle: TextStyle(
                      fontFamily: kSerif,
                      letterSpacing: 1,
                      color: AppColors.slate,
                    ),
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    for (final TypeDT option in session.base.typesDT)
                      DropdownMenuItem<String>(
                        value: option.code,
                        // La famille porte deja son prefixe (« DT 1500 »,
                        // « ADT ») : on n'en ajoute pas un second.
                        child: Text(
                          '${option.libelle}  (${option.nombreDts})',
                        ),
                      ),
                  ],
                  onChanged: (String? code) {
                    if (code == null) return;
                    setStateDialog(() {
                      typeChoisi = code;
                      // Les identifiants sont non redondants : changer de
                      // famille invalide le numero retenu, on le remet a
                      // zero plutot que de garder un DT mal classe.
                      final TypeDT? nouvelle = session.base.typeDT(code);
                      if (idDtChoisi != null &&
                          nouvelle?.contient(idDtChoisi!) != true) {
                        idDtChoisi = null;
                      }
                    });
                  },
                ),
                const SizedBox(height: 14),
                // Liste 2 : les DT de la famille choisie. Le menu se remplit
                // en fonction de la premiere liste.
                DropdownButtonFormField<String>(
                  initialValue: idDtChoisi,
                  isExpanded: true,
                  hint: Text(
                    famille == null
                        ? 'Aucun DT'
                        : 'Select dans ${famille.libelle}',
                    style: TextStyle(
                      fontFamily: kSerif,
                      fontSize: (13 * MiseEnPage.depuis(context).k).clamp(10.0, 13.0),
                      color: AppColors.greyText,
                    ),
                  ),
                  style: TextStyle(
                    fontFamily: kSerif,
                    fontSize: (14 * MiseEnPage.depuis(context).k).clamp(10.0, 14.0),
                    color: AppColors.ink,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Id DT',
                    labelStyle: TextStyle(
                      fontFamily: kSerif,
                      letterSpacing: 1,
                      color: AppColors.slate,
                    ),
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    for (final String id in session.idsDuType(typeChoisi))
                      DropdownMenuItem<String>(
                        value: id,
                        // Le numero est nu dans la base (« 5 ») : c'est
                        // l'identifiant unique sur tout le parc, pas un
                        // code a prefixer.
                        child: Text(id),
                      ),
                  ],
                  onChanged: (String? id) =>
                      setStateDialog(() => idDtChoisi = id),
                ),
                const SizedBox(height: 14),
                // Picture : un bouton, pas une case a cocher. Il demande
                // d'abord la source (appareil photo ou galerie), puis
                // affiche la vignette de l'image retenue.
                _BoutonPhoto(
                  photo: photo,
                  onTap: choisirPhoto,
                  onClear: photo == null
                      ? null
                      : () => setStateDialog(() => photo = null),
                ),
                TextField(
                  controller: comment,
                  decoration: const InputDecoration(labelText: 'Comment'),
                ),
                if (erreur != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    erreur!,
                    style: TextStyle(color: AppColors.red, fontSize: (12 * MiseEnPage.depuis(context).k).clamp(9.0, 12.0)),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Annuler'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.slate,
                foregroundColor: Colors.white,
              ),
              onPressed: () {
                if (idDtChoisi == null) {
                  // Le dialogue reste ouvert : la photo et le commentaire deja
                  // saisis ne sont pas perdus, l'utilisateur complete la
                  // selection et revalide.
                  setStateDialog(() {
                    erreur = 'Choisissez un numero de DT dans le lot '
                        '$typeChoisi avant d\'enregistrer';
                  });
                  return;
                }
                Navigator.pop(context, true);
              },
              child: const Text('Enregistrer'),
            ),
          ],
        );
        },
      ),
    );

    final String commentaire = comment.text.trim();
    comment.dispose();

    if (saved != true) return;

    // Dart ne promeut pas cette variable : elle est reassignee par les
    // closures du formulaire. On fige la valeur retenue avant l'ecriture.
    final String idRetenu = idDtChoisi ?? '';
    final Uint8List? octetsPhoto = photo;
    if (idRetenu.isEmpty) return;

    final DateTime now = DateTime.now();
    final bool ok = session.ajouterLigne(
      LigneBlast(
        time:
            '${now.hour.toString().padLeft(2, '0')}h'
            '${now.minute.toString().padLeft(2, '0')}',
        dt: typeChoisi,
        idDt: idRetenu,
        hasPicture: octetsPhoto != null,
        photo: octetsPhoto,
        comment: commentaire,
      ),
    );

    if (!ok) return;
    session.push(
      'Ligne ajoutee - blast ${blast.numero}, bloc ${bloc.numero} '
      '(carte ${blast.carte})',
    );
    setState(() {});
  }

  /// Confirmation avant de fermer le **bloc courant** (paire blast/bloc) :
  /// la validation est definitive pour ce bloc, on ne peut plus rien y
  /// ajouter ensuite — les autres blocs du blast ne sont pas touches.
  Future<void> _toggleLock() async {
    final Blast? blast = _blast;
    final BlocTravail? bloc = _bloc;
    if (blast == null || bloc == null) return;

    if (bloc.verrouille) {
      final bool? ouvrir = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(
            'Deverrouiller le bloc ${bloc.numero} '
            'du blast ${blast.numero} ?',
          ),
          content: const Text(
            'Vous pourrez de nouveau ajouter des lignes dans ce bloc.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Annuler'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.slate,
                foregroundColor: Colors.white,
              ),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Deverrouiller'),
            ),
          ],
        ),
      );
      if (ouvrir == true) session.deverrouillerBloc();
      return;
    }

    final int sansPicture = bloc.lignes
        .where((LigneBlast l) => !l.hasPicture)
        .length;

    final bool? valider = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          'Enregistrer et verrouiller le bloc ${bloc.numero} '
          'du blast ${blast.numero} ?',
        ),
        content: Text(
          '${bloc.nombreLignes} ligne(s) enregistree(s) dans ce bloc.\n\n'
          'Aucune ligne ne pourra plus etre ajoutee dans ce bloc. Les autres '
          'blocs du blast restent ouverts, et vous pourrez toujours consulter '
          'les donnees et changer de bloc ou de blast.\n\n'
          'Sans picture : $sansPicture',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Annuler'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.slate,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Enregistrer'),
          ),
        ],
      ),
    );

    if (valider == true) session.verrouillerBloc();
  }

  /// Nombre de lignes du perimetre d'envoi courant, selon [Session.envoiMode].
  int get _lignesDuPerimetre {
    final Blast? blast = _blast;
    if (blast == null) return 0;
    switch (session.envoiMode) {
      case BaseLocale.envoiModeBloc:
        return _bloc?.nombreLignes ?? 0;
      case BaseLocale.envoiModeVerrouilles:
        return blast.blocs
            .where((BlocTravail b) => b.verrouille)
            .fold<int>(0, (int t, BlocTravail b) => t + b.nombreLignes);
      default:
        return _lignesDuBlast;
    }
  }

  /// Nombre de blocs du perimetre d'envoi courant.
  int get _blocsDuPerimetre {
    final Blast? blast = _blast;
    if (blast == null) return 0;
    switch (session.envoiMode) {
      case BaseLocale.envoiModeBloc:
        return _bloc == null ? 0 : 1;
      case BaseLocale.envoiModeVerrouilles:
        return blast.blocs.where((BlocTravail b) => b.verrouille).length;
      default:
        return blast.nombreBlocs;
    }
  }

  /// Vrai si le perimetre du mode courant est pret a partir : verrouille et
  /// non vide. C'est ce que compte le bouton `Envoyer`.
  bool get _envoiPret {
    final Blast? blast = _blast;
    if (blast == null) return false;
    if (blast.envoye) return false;
    switch (session.envoiMode) {
      case BaseLocale.envoiModeBloc:
        final BlocTravail? bloc = _bloc;
        return bloc != null && bloc.verrouille && bloc.nombreLignes > 0;
      case BaseLocale.envoiModeVerrouilles:
        return _blocsDuPerimetre > 0 && _lignesDuPerimetre > 0;
      default:
        return blast.verrouille && _lignesDuBlast > 0;
    }
  }

  /// Annonce le refus que la base produirait, avant d'ouvrir la fenetre.
  /// Inutile de proposer un envoi que la base refusera ; elle reste elle
  /// seule juge au moment de l'ecriture.
  String? _motifEnvoiImpossible() {
    final Blast? blast = _blast;
    if (blast == null) return 'Aucun blast selectionne : rien a envoyer';
    switch (session.envoiMode) {
      case BaseLocale.envoiModeBloc:
        final BlocTravail? bloc = _bloc;
        if (bloc == null) return 'Aucun bloc selectionne : rien a envoyer';
        if (!bloc.verrouille) {
          return 'Bloc ${bloc.numero} non verrouille : verrouillez-le avant '
              'd\'envoyer les donnees';
        }
        if (bloc.nombreLignes == 0) {
          return 'Bloc ${bloc.numero} sans donnee : rien a envoyer';
        }
      case BaseLocale.envoiModeVerrouilles:
        if (_blocsDuPerimetre == 0) {
          return 'Aucun bloc verrouille dans le blast ${blast.numero} : '
              'verrouillez au moins un bloc avant d\'envoyer';
        }
        if (_lignesDuPerimetre == 0) {
          return 'Aucune donnee dans les blocs verrouilles : rien a envoyer';
        }
      default:
        if (!blast.verrouille) {
          return 'Blast ${blast.numero} non verrouille : verrouillez-le avant '
              'd\'envoyer les donnees';
        }
        if (blast.nombreLignes == 0) {
          return 'Blast ${blast.numero} sans donnee : rien a envoyer';
        }
    }
    if (blast.envoye) return 'Blast ${blast.numero} deja envoye';
    return null;
  }

  /// Transmet les donnees sauvegardees du perimetre courant au point d'acces.
  ///
  /// La fenetre annonce le perimetre exact du mode en cours : blast entier,
  /// bloc courant ou blocs verrouilles.
  Future<void> _envoyer() async {
    final Blast? blast = _blast;
    if (blast == null) return;

    final String? motif = _motifEnvoiImpossible();
    if (motif != null) {
      session.push(motif);
      return;
    }

    final String perimetre;
    switch (session.envoiMode) {
      case BaseLocale.envoiModeBloc:
        perimetre =
            'Bloc ${_bloc!.numero} du blast ${blast.numero} - '
            '${_bloc!.nombreLignes} ligne(s), carte ${blast.carte}.';
      case BaseLocale.envoiModeVerrouilles:
        perimetre =
            'Les $_blocsDuPerimetre bloc(s) verrouille(s) du blast '
            '${blast.numero} - $_lignesDuPerimetre ligne(s), '
            'carte ${blast.carte}.';
      default:
        perimetre =
            '$_lignesDuBlast ligne(s) sur ${blast.nombreBlocs} bloc(s), '
            'carte ${blast.carte}.';
    }

    final bool? confirme = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Envoyer les donnees du blast ${blast.numero} ?'),
        content: Text(
          '$perimetre\n\n'
          'Les donnees sauvegardees seront transmises au point d\'acces '
          'Master.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Annuler'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.slate,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Envoyer'),
          ),
        ],
      ),
    );

    if (confirme == true) session.envoyerDonnees();
  }

  /// Les deux listes deroulantes lisent la base, jamais une liste en dur :
  /// `Select blast` et `Select bloc` y puisent leurs options.
  Future<void> _choisirBlast() async {
    final List<String> numeros = session.base.numerosBlast;
    final String? choisi = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Select blast'),
        children: [
          for (final numero in numeros)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, numero),
              child: _BlastOption(
                numero: numero,
                blast: session.base.parNumero(numero)!,
                actif: numero == _blast?.numero,
              ),
            ),
        ],
      ),
    );
    if (choisi != null) session.selectionnerBlast(choisi);
  }

  /// Ouvre la liste des RL (flitches) du blast courant.
  Future<void> _choisirRL() async {
    final Blast? blast = _blast;
    if (blast == null) return;
    final List<String> rls = blast.rls;
    if (rls.isEmpty) return;
    final String? choisi = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Select RL'),
        children: [
          for (final String rl in rls)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, rl),
              child: _RlOption(
                rl: rl,
                carte: blast.carteDuRl(rl),
                libelle: session.base.libelleCarte(blast.carteDuRl(rl) ?? ''),
                actif: rl == session.rlCourant,
                nombreBlocs: blast.blocsDuRl(rl).length,
              ),
            ),
        ],
      ),
    );
    if (choisi != null) session.selectionnerRL(choisi);
  }

  Future<void> _choisirBloc() async {
    final Blast? blast = _blast;
    if (blast == null) return;
    // Le RL courant fait foi : on n'affiche QUE ses blocs. Aucun repli sur
    // les blocs des autres RL — sinon un RL sans bloc (ou pas encore
    // synchronise) afficherait les blocs du premier RL.
    final String rl = session.rlCourant;
    final List<BlocTravail> liste =
        rl.isEmpty ? blast.blocs : blast.blocsDuRl(rl);
    if (liste.isEmpty) {
      session.push(
        rl.isEmpty
            ? 'Aucun bloc sur le blast ${blast.numero}'
            : 'Aucun bloc sur le RL $rl',
      );
      return;
    }
    final String carteRl = session.carteCourante;
    final String? choisi = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(rl.isEmpty ? 'Select bloc' : 'Select bloc - RL $rl'),
        children: [
          for (final bloc in liste)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, bloc.numero),
              child: _BlocOption(
                bloc: bloc,
                carte: carteRl,
                actif: bloc == _bloc,
              ),
            ),
        ],
      ),
    );
    if (choisi != null) session.selectionnerBloc(choisi);
  }

  /// Ouvre le plan du blast courant en PLEIN ECRAN.
  ///
  /// La vignette du bouton `Afficher map` est trop petite pour lire un plan
  /// de tir : un tap ouvre une fenetre plein cadre, fond noir, avec
  /// pinch-to-zoom (deux doigts) et double-tap pour zoomer/dezoomer.
  ///
  /// Un tap simple sur le fond noir ferme la fenetre ; le bouton explicite
  /// `Fermer` reste dans le bandeau pour les utilisateurs qui le preferent.
  void _afficherCarte() {
    final Blast? blast = _blast;
    if (blast == null) return;

    final String codeCarte = session.carteCourante.isNotEmpty
        ? session.carteCourante
        : blast.carte;
    final String libelle = session.base.libelleCarte(codeCarte) ?? '';
    // Pas de repli sur `blast.plan` : il ne porte que la carte du premier RL.
    final String chemin = session.planCourant ?? '';

    // Diagnostic : trace la chaine complete RL -> carte -> plan. Permet de
    // verifier depuis `adb logcat` que le changement de RL change bien de
    // carte et de plan, sans deviner.
    debugPrint('[CARTE] blast=${blast.numero} rl=${session.rlCourant} '
        'cartes=${blast.cartes} -> carte=$codeCarte '
        'plan=$chemin');

    showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Fermer la carte',
      barrierColor: Colors.black87,
      transitionDuration: const Duration(milliseconds: 180),
      pageBuilder: (context, animation, secondaryAnimation) =>
          _PleinEcranCarte(
        codeCarte: codeCarte,
        libelle: libelle,
        blast: blast.numero,
        chemin: chemin,
      ),
      transitionBuilder: (context, animation, secondary, child) =>
          FadeTransition(opacity: animation, child: child),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Toute lecture de la selection (blast, bloc, ligne, verrou) se fait
    // DANS le builder du ListenableBuilder : lu avant, elle serait figee au
    // dernier build de cet etat, et les boutons afficheraient encore l'ancien
    // choix alors que la session a deja change.
    return ProfileShell(
      session: session,
      voyants: ProfilVoyants.spotter,
      body: ListenableBuilder(
        listenable: session,
        builder: (context, _) {
          final MiseEnPage mise = MiseEnPage.depuis(context);
          final Blast? blast = _blast;
          final BlocTravail? bloc = _bloc;

          return Padding(
            padding: mise.margeEcran,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Cinq boutons d'un meme rang ne tiennent plus des qu'une
                // fenetre fait moins de 700 px de contenu : on coupe en deux
                // ranges (selection, puis carte + verrou + envoi) plutot que
                // d'ecraser les boutons jusqu'a ce qu'ils debordent.
                LayoutBuilder(
                  builder: (context, contraintes) {
                    final List<Widget> boutons = [
                      _FilterButton(
                        titre: 'Select blast',
                        valeur: blast == null ? null : 'Blast ${blast.numero}',
                        detail: blast == null
                            ? null
                            : (blast.rls.isNotEmpty
                                ? '${blast.rls.length} RL'
                                : '${blast.nombreBlocs} bloc(s)'),
                        onTap: _choisirBlast,
                      ),
                      _FilterButton(
                        titre: 'RL',
                        valeur: session.rlCourant.isEmpty ? null : 'RL ${session.rlCourant}',
                        detail: blast == null || blast.rls.isEmpty
                            ? null
                            : '${blast.blocsDuRl(session.rlCourant).length} bloc(s)',
                        onTap: (blast == null || blast.rls.isEmpty) ? null : _choisirRL,
                      ),
                      _FilterButton(
                        titre: 'Select bloc',
                        valeur: bloc?.numero == null ? null : 'Bloc ${bloc!.numero}',
                        detail: bloc == null
                            ? null
                            : '${bloc.nombreLignes} ligne(s)'
                                  '${bloc.verrouille ? ' - verrouille' : ''}',
                        onTap: _choisirBloc,
                      ),
                      // La carte appartient au blast et au RL courant.
                      _FilterButton(
                        titre: 'Afficher map',
                        valeur: session.carteCourante.isNotEmpty
                            ? session.carteCourante
                            : blast?.carte,
                        detail: session.carteCourante.isEmpty
                            ? null
                            : session.base.libelleCarte(session.carteCourante),
                        lectureSeule: true,
                        apercu: session.planCourant,
                        onTap: _afficherCarte,
                      ),
                      // Le cadenas porte sur le bloc courant (paire
                      // blast/bloc) : verrouiller le bloc 8 n'empeche pas
                      // d'ecrire dans le bloc 6 du meme blast.
                      _LockButton(
                        verrouille: _verrouille,
                        numero: bloc?.numero,
                        onTap: _toggleLock,
                      ),
                      // L'envoi porte ce qui est deja enregistre : le perimetre
                      // depend du mode (blast, bloc courant ou blocs
                      // verrouilles), et le bouton se fige une fois l'envoi fait.
                      _SendButton(
                        pret: _envoiPret,
                        envoye: blast?.envoye ?? false,
                        onTap: _envoyer,
                      ),
                    ];

                    final List<Widget> ecarts = [
                      for (var i = 1; i < boutons.length; i++)
                        SizedBox(width: (8 * mise.k).clamp(3.0, 8.0)),
                    ];

                    if (contraintes.maxWidth < 860) {
                      return Column(
                        children: [
                          Row(
                            children: [
                              Expanded(child: boutons[0]),
                              SizedBox(width: (8 * mise.k).clamp(3.0, 8.0)),
                              Expanded(child: boutons[1]),
                              SizedBox(width: (8 * mise.k).clamp(3.0, 8.0)),
                              Expanded(child: boutons[2]),
                            ],
                          ),
                          SizedBox(height: (8 * mise.k).clamp(3.0, 8.0)),
                          Row(
                            children: [
                              Expanded(child: boutons[3]),
                              SizedBox(width: (8 * mise.k).clamp(3.0, 8.0)),
                              Expanded(child: boutons[4]),
                              SizedBox(width: (8 * mise.k).clamp(3.0, 8.0)),
                              Expanded(child: boutons[5]),
                            ],
                          ),
                        ],
                      );
                    }

                    return Row(
                      children: [
                        for (var i = 0; i < boutons.length; i++) ...[
                          if (i > 0) ecarts[i - 1],
                          Expanded(child: boutons[i]),
                        ],
                      ],
                    );
                  },
                ),
                SizedBox(height: (10 * mise.k).clamp(4.0, 10.0)),
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      border: Border.all(color: AppColors.border, width: 1.5),
                    ),
                    child: Column(
                    children: [
                        SizedBox(
                          height: MediaQuery.sizeOf(context).height < 400 ? 22 : 34,
                          child: const _TableHeader(),
                        ),
                        Expanded(
                          // Un bloc peut contenir une centaine de lignes :
                          // la liste doit defiler sous l'en-tete.
                          child: _lignes.isEmpty
                              ? const _Vide()
                              : ListView.separated(
                                  padding: EdgeInsets.zero,
                                  itemCount: _lignes.length,
                                  separatorBuilder: (context, _) =>
                                      const Divider(height: 1),
                                  itemBuilder: (context, i) => _TableRow(
                                    ligne: _lignes[i],
                                    blast: blast?.numero ?? '-',
                                    bloc: bloc?.numero ?? '-',
                                  ),
                                ),
                        ),
                        SizedBox(
                          height: MediaQuery.sizeOf(context).height < 400 ? 18 : 28,
                          child: _AddStrip(
                            onAdd: (blast == null ||
                                  bloc == null ||
                                  bloc.verrouille)
                              ? null
                              : _addRecord,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                SizedBox(height: 6 * mise.k),
                // Relecture (rapport 14/10 §1.2) : photos, historique,
                // compte-rendu de mission. Trois boutons d'acces aux
                // panneaux de lecture de la base locale.
                LayoutBuilder(
                  builder: (context, contraintes) {
                    final double hauteur = contraintes.maxHeight.isFinite
                        ? contraintes.maxHeight
                        : 48;
                    final bool compact = hauteur < 60;
                    final List<Widget> relire = [
                      _BoutonRelire(
                        icone: Icons.photo_library_outlined,
                        libelle: 'Captures',
                        compact: compact,
                        onTap: () => ouvrirVisionneusePhotos(context, session),
                      ),
                      _BoutonRelire(
                        icone: Icons.history,
                        libelle: 'Historique',
                        compact: compact,
                        onTap: () => ouvrirHistorique(context, session),
                      ),
                      _BoutonRelire(
                        icone: Icons.fact_check_outlined,
                        libelle: 'Compte-rendu',
                        compact: compact,
                        onTap: () => ouvrirCompteRendu(context, session),
                      ),
                    ];
                    if (contraintes.maxWidth < 700) {
                      return Row(
                        children: [
                          for (var i = 0; i < relire.length; i++) ...[
                            if (i > 0) SizedBox(width: (8 * mise.k).clamp(3.0, 8.0)),
                            Expanded(child: relire[i]),
                          ],
                        ],
                      );
                    }
                    return Row(
                      children: [
                        for (int i = 0; i < relire.length; i++) ...[
                          if (i > 0) SizedBox(width: (8 * mise.k).clamp(3.0, 8.0)),
                          Expanded(child: relire[i]),
                        ],
                      ],
                    );
                  },
                ),
                SizedBox(height: 6 * mise.k),
                // Une seule ligne : ce texte se repliait sur deux lignes en
                // fenetre basse (libelle long avec compteurs), ajoutant ~26 px
                // a une colonne dont les autres blocs sont a hauteur fixe —
                // d'ou le debordement de 26 px signale en paysage tablette.
                // Il s'abrege desormais par ellipse au lieu de pousser le
                // tableau (meme logique que `_TableHeader`).
                Text(
                  blast == null && session.base.numerosBlast.isEmpty
                      ? 'Aucun blast - en attente du serveur'
                      : blast == null || bloc == null
                            ? 'Aucun bloc selectionne'
                            : 'Bloc ${bloc.numero} - carte ${blast.carte} - '
                                  '${_lignes.length} ligne(s) affichee(s) sur '
                                  '$_lignesDuBlast pour le blast ${blast.numero}',
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: (13 * mise.k).clamp(10.0, 13.0),
                    color: AppColors.greyText,
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

/// Plan d'une carte : asset embarque, URL reseau (Drive) ou fichier local.
///
/// Trois cas, dans l'ordre de priorite :
/// - `http(s)://` : le plan n'a pas encore ete telecharge, on l'affiche
///   directement depuis le reseau (`Image.network`) ;
/// - `assets/...` : plan embarque dans l'application ;
/// - tout le reste : chemin de fichier local pose par le worker de synchro.
class _ImagePlan extends StatelessWidget {
  const _ImagePlan({required this.chemin, this.fit = BoxFit.contain});

  final String chemin;
  final BoxFit fit;

  bool get _estReseau =>
      chemin.startsWith('http://') || chemin.startsWith('https://');

  bool get _estAsset => chemin.startsWith('assets/');

  static Widget _erreur(BuildContext context) => const Center(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.map_outlined, size: 40, color: AppColors.slate),
              SizedBox(height: 10),
              Text(
                'Plan non disponible pour ce RL',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.slate, fontSize: 15),
              ),
              SizedBox(height: 6),
              Text(
                'Lancez Actualiser pour telecharger le plan de cette carte.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: AppColors.greyText),
              ),
            ],
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    // Aucun plan connu pour cette carte : etat vide explicite plutot qu'un
    // `File('')` qui leve une exception au premier rendu.
    if (chemin.isEmpty) return _erreur(context);
    if (_estReseau) {
      return Image.network(
        chemin,
        // Pas de `gaplessPlayback` ici : entre deux RL d'un meme blast, le
        // plan doit etre REMPLACE, pas conserve. Avec gapless, Flutter
        // laissait l'ancienne carte (RL 260) affichee pendant le chargement
        // de la nouvelle, et le resultat restait bloque sur la premiere.
        key: ValueKey<String>('reseau:$chemin'),
        fit: fit,
        loadingBuilder: (context, child, progression) {
          if (progression == null) return child;
          final int recu = progression.cumulativeBytesLoaded;
          final int? total = progression.expectedTotalBytes;
          return Center(
            child: SizedBox(
              width: 40,
              height: 40,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                value: total == null || total <= 0 ? null : recu / total,
                color: AppColors.slate,
              ),
            ),
          );
        },
        errorBuilder: (context, error, stack) => Center(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.broken_image_outlined,
                    size: 32, color: AppColors.slate),
                const SizedBox(height: 8),
                const Text(
                  'Plan introuvable',
                  style: TextStyle(color: AppColors.slate),
                ),
                const SizedBox(height: 4),
                Text(
                  'Verifiez que le fichier est partage avec le lien',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 11,
                    color: AppColors.greyText,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    if (_estAsset) {
      return Image.asset(
        chemin,
        key: ValueKey<String>('asset:$chemin'),
        fit: fit,
        errorBuilder: (context, error, stack) => _erreur(context),
      );
    }
    return Image.file(
      File(chemin),
      // Cle sur le chemin : changer de RL change de fichier, donc de widget.
      key: ValueKey<String>('fichier:$chemin'),
      fit: fit,
      errorBuilder: (context, error, stack) => _erreur(context),
    );
  }
}

      /// Plan en PLEIN ECRAN, zoomable.
      ///
      /// Ouvert par un tap sur le bouton `Afficher map`. Le plan occupe toute la
      /// surface utile et se manipule aux gestes :
      /// - **pinch** (deux doigts) : zoom libre entre 1x et 8x ;
      /// - **double-tap** : bascule entre « ajuste a l'ecran » et « zoom x3 » ;
      /// - **drag a un doigt** : deplacement quand l'image est zoomee.
      ///
      /// Un bandeau superieur discret rappelle le code de carte et le blast, avec
      /// le bouton `Fermer`. Le fond noir fait ressortir le plan.
      class _PleinEcranCarte extends StatefulWidget {
        const _PleinEcranCarte({
          required this.codeCarte,
          required this.libelle,
          required this.blast,
          required this.chemin,
        });

        final String codeCarte;
        final String libelle;
        final String blast;
        final String chemin;

        @override
        State<_PleinEcranCarte> createState() => _PleinEcranCarteState();
      }

      class _PleinEcranCarteState extends State<_PleinEcranCarte> {
        /// Controleur de transformation : permet le double-tap zoom/dezoom.
        final TransformationController _zoom = TransformationController();

        static const double _zoomDoubleTap = 3.0;

        @override
        void dispose() {
          _zoom.dispose();
          super.dispose();
        }

        /// Double-tap : alterne entre vue ajustee (1x) et zoom [_zoomDoubleTap].
        void _doubleTap() {
          if (_zoom.value.getMaxScaleOnAxis() > 1.05) {
            _zoom.value = Matrix4.identity();
          } else {
            _zoom.value = Matrix4.identity()..scaleByDouble(
                _zoomDoubleTap, _zoomDoubleTap, _zoomDoubleTap, 1.0);
          }
        }

        @override
        Widget build(BuildContext context) {
          final MiseEnPage mise = MiseEnPage.depuis(context);
          final double k = mise.k;

          return Scaffold(
            backgroundColor: Colors.black,
            body: SafeArea(
              child: Column(
                children: [
                  // Bandeau superieur : identification + fermeture.
                  Container(
                    padding: EdgeInsets.symmetric(
                      horizontal: (14 * k).clamp(10.0, 16.0),
                      vertical: (8 * k).clamp(6.0, 10.0),
                    ),
                    color: Colors.black,
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                'Carte ${widget.codeCarte}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontFamily: kSerif,
                                  fontSize: (17 * k).clamp(13.0, 18.0),
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white,
                                ),
                              ),
                              if (widget.libelle.isNotEmpty)
                                Text(
                                  'Blast ${widget.blast} - ${widget.libelle}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: (12 * k).clamp(10.0, 12.0),
                                    color: Colors.white70,
                                  ),
                                ),
                              // Diagnostic TEMPORAIRE : montre la source
                              // reellement chargee (ID Drive ou chemin local).
                              // A retirer une fois le multi-RL valide.
                              Text(
                                'src: ${widget.chemin}',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: (9 * k).clamp(8.0, 10.0),
                                  color: Colors.amberAccent,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          key: const ValueKey<String>('carte-reset-zoom'),
                          onPressed: _doubleTap,
                          tooltip: 'Zoom / ajuster',
                          icon: const Icon(Icons.zoom_out_map,
                              color: Colors.white, size: 26),
                        ),
                        IconButton(
                          key: const ValueKey<String>('carte-fermer'),
                          onPressed: () => Navigator.of(context).pop(),
                          tooltip: 'Fermer',
                          icon: const Icon(Icons.close,
                              color: Colors.white, size: 28),
                        ),
                      ],
                    ),
                  ),
                  // Plan : toute la place restante, zoom + double-tap.
                  Expanded(
                    child: GestureDetector(
                      onDoubleTap: _doubleTap,
                      child: InteractiveViewer(
                        transformationController: _zoom,
                        minScale: 1.0,
                        maxScale: 8.0,
                        // La carte est un plan taille : on peut la deplacer en
                        // entier une fois zoomee.
                        boundaryMargin: const EdgeInsets.all(double.infinity),
                        child: SizedBox.expand(
                          child: _ImagePlan(
                            chemin: widget.chemin,
                            fit: BoxFit.contain,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        }
      }

      class _BlastOption extends StatelessWidget {
  const _BlastOption({
    required this.numero,
    required this.blast,
    required this.actif,
  });

  final String numero;
  final Blast blast;
  final bool actif;

  @override
  Widget build(BuildContext context) {
    final int nbRl = blast.rls.length;
    final String infoRl = nbRl > 0 ? '$nbRl RL' : '';
    final String infoBlocs = '${blast.nombreBlocs} bloc(s)';
    final String detail = [infoRl, infoBlocs].where((s) => s.isNotEmpty).join(' · ');

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Flexible(
          child: Text(
            'Blast $numero',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontWeight: actif ? FontWeight.bold : FontWeight.normal,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            '$detail${blast.verrouille ? ' - verrouille' : ''}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.right,
            style: TextStyle(
              fontSize: (12 * MiseEnPage.depuis(context).k).clamp(9.0, 12.0),
              color: AppColors.slate,
            ),
          ),
        ),
      ],
    );
  }
}

/// Bouton « Picture » du formulaire.
///
/// Ce n'est pas une case a cocher : un tap demande d'abord la source
/// (appareil photo Android ou image deja presente dans le telephone), puis
/// la vignette de l'image retenue remplace le texte. Le X permet de retirer
/// une photo prise par erreur.
class _BoutonPhoto extends StatelessWidget {
  const _BoutonPhoto({
    required this.photo,
    required this.onTap,
    this.onClear,
  });

  final Uint8List? photo;
  final VoidCallback onTap;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final bool pris = photo != null;
    final double k = MiseEnPage.depuis(context).k;

    return Material(
      color: pris ? const Color(0xFFF7F9F5) : Colors.white,
      child: InkWell(
        onTap: onTap,
        child: Container(
          width: double.infinity,
          padding: EdgeInsets.symmetric(horizontal: 10 * k, vertical: 8 * k),
          decoration: BoxDecoration(
            border: Border.all(
              color: AppColors.border,
              width: 1.5,
            ),
          ),
          child: Row(
            children: [
              Icon(
                Icons.photo_camera,
                size: (22 * k).clamp(16.0, 22.0),
                color: AppColors.green,
              ),
              SizedBox(width: 8 * k),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Picture',
                      style: TextStyle(
                        fontFamily: kSerif,
                        fontSize: (14 * k).clamp(10.0, 14.0),
                        color: AppColors.ink,
                      ),
                    ),
                    Text(
                      pris
                          ? 'Photo chargee - retoucher'
                          : 'Prendre une photo ou charger une image',
                      style: TextStyle(
                        fontSize: (11 * k).clamp(9.0, 11.0),
                        color: AppColors.greyText,
                      ),
                    ),
                  ],
                ),
              ),
              if (pris) ...[
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: Image.memory(
                    photo!,
                    width: (56 * k).clamp(42.0, 56.0),
                    height: (38 * k).clamp(28.0, 38.0),
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                    errorBuilder: (context, error, stack) => Container(
                      width: (56 * k).clamp(42.0, 56.0),
                      height: (38 * k).clamp(28.0, 38.0),
                      color: AppColors.greyBg,
                      child: const Icon(Icons.broken_image, size: 18),
                    ),
                  ),
                ),
                SizedBox(width: 4 * k),
                SizedBox(
                  width: (40 * k).clamp(36.0, 40.0),
                  height: (40 * k).clamp(36.0, 40.0),
                  child: InkWell(
                    onTap: onClear,
                    child: const Center(
                      child: Padding(
                        padding: EdgeInsets.all(4),
                        child: Icon(
                          Icons.close,
                          size: 20,
                          color: AppColors.slate,
                        ),
                      ),
                    ),
                  ),
                ),
              ] else
                const Icon(
                  Icons.chevron_right,
                  size: 26,
                  color: AppColors.border,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Une option RL (flitch) de la liste « Select RL ».
class _RlOption extends StatelessWidget {
  const _RlOption({
    required this.rl,
    required this.carte,
    required this.libelle,
    required this.actif,
    required this.nombreBlocs,
  });

  final String rl;
  final String? carte;
  final String? libelle;
  final bool actif;
  final int nombreBlocs;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Flexible(
          child: Text(
            'RL $rl',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontWeight: actif ? FontWeight.bold : FontWeight.normal,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            carte == null
                ? '$nombreBlocs bloc(s)'
                : '$carte - $nombreBlocs bloc(s)',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.right,
            style: const TextStyle(fontSize: 13, color: AppColors.slate),
          ),
        ),
      ],
    );
  }
}

/// Un bloc de la liste « Select bloc », avec la carte du blast dont il tient.
///
/// La carte est reportee par la vue : elle appartient au blast, pas au bloc,
/// donc on ne la lit pas sur l'entite. Le cadenas signale un bloc verrouille
/// (paire blast/bloc) : la saisie y est fermee, mais le bloc reste choissable
/// pour le consulter.
class _BlocOption extends StatelessWidget {
  const _BlocOption({
    required this.bloc,
    required this.carte,
    required this.actif,
  });

  final BlocTravail bloc;

  /// Carte du blast qui contient [bloc].
  final String carte;
  final bool actif;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Flexible(
          child: Row(
            children: [
              Flexible(
                child: Text(
                  'Bloc ${bloc.numero}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (bloc.verrouille) ...[
                const SizedBox(width: 6),
                const Icon(
                  Icons.lock,
                  size: 15,
                  color: AppColors.slate,
                ),
              ],
            ],
          ),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            // On affiche le RL (flitch) de la carte : c'est ce qui permet de
            // voir d'un coup d'oeil a quel RL appartient le bloc. Le code
            // complet de la carte reste en info-bulle.
            '${decoderCarte(bloc.carte)?.flitch ?? carte}'
            ' - ${bloc.nombreLignes} ligne(s)'
            '${bloc.verrouille ? ' - verrouille' : ''}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.right,
            style: const TextStyle(fontSize: 13, color: AppColors.slate),
          ),
        ),
      ],
    );
  }
}

class _Vide extends StatelessWidget {
  const _Vide();

  @override
  Widget build(BuildContext context) {
    final double k = MiseEnPage.depuis(context).k;
    return Center(
      child: Text(
        'Aucune ligne sur ce bloc',
        style: TextStyle(fontSize: (13 * k).clamp(10.0, 13.0), color: AppColors.greyText),
      ),
    );
  }
}

const _columns = [
  'Times',
  'Blast',
  'Bloc',
  'DT',
  'Id DT',
  'Picture',
  'Comment',
];
const _weights = [1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.7];

class _TableHeader extends StatelessWidget {
  const _TableHeader();

  @override
  Widget build(BuildContext context) {
    // En-tete du tableau : hauteur libre bornee par la place restante. Les
    // 46 px de reference sont un plafond, pas une exigence : sur une fenetre
    // basse l'en-tete se comprime au lieu de pousser le tableau hors de
    // l'ecran.
    return Container(
      color: AppColors.bar,
      constraints: BoxConstraints(
        maxHeight: (40 * MiseEnPage.depuis(context).k).clamp(28.0, 40.0),
      ),
      height: double.infinity,
      child: Row(
        children: [
          for (var i = 0; i < _columns.length; i++)
            Expanded(
              flex: (_weights[i] * 10).round(),
              child: Container(
                alignment: Alignment.center,
                decoration: i == 0
                    ? null
                    : const BoxDecoration(
                        border: Border(
                          left: BorderSide(color: Colors.white, width: 1),
                        ),
                      ),
                child: Text(
                  _columns[i].spaced,
                  style: TextStyle(
                    fontFamily: kSerif,
                    fontSize: (13 * MiseEnPage.depuis(context).k).clamp(10.0, 13.0),
                    letterSpacing: 0.5,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _TableRow extends StatelessWidget {
  const _TableRow({
    required this.ligne,
    required this.blast,
    required this.bloc,
  });

  final LigneBlast ligne;

  /// Blast et bloc de la ligne, redonnes a l'affichage : ils sont portes par
  /// l'arbre, pas par la ligne.
  final String blast;
  final String bloc;

  @override
  Widget build(BuildContext context) {
    // DT est la categorie, Id DT le numero du DT dans cette categorie : deux
    // colonnes distinctes, comme dans le formulaire.
    final values = [
      ligne.time,
      blast,
      bloc,
      ligne.dt,
      ligne.idDt,
      '',
      ligne.comment,
    ];
    return SizedBox(
      // 44 px en reference, mais jamais plus que la place disponible : idem
      // l'en-tete, la ligne se comprime sur une fenetre basse.
      height: (44 * MiseEnPage.depuis(context).k).clamp(28.0, 44.0),
      child: Row(
        children: [
          for (var i = 0; i < values.length; i++)
            Expanded(
              flex: (_weights[i] * 10).round(),
              child: Container(
                alignment: Alignment.center,
                decoration: i == 0
                    ? null
                    : const BoxDecoration(
                        border: Border(
                          left: BorderSide(color: AppColors.border, width: 1),
                        ),
                      ),
                child: i == 5
                    ? InkWell(
                        onTap: () => _voirPhoto(context, ligne),
                        child: Icon(
                          ligne.hasPicture
                              ? Icons.document_scanner
                              : Icons.add_a_photo_outlined,
                          size: 20,
                          color: AppColors.green,
                        ),
                      )
                    : Text(
                        values[i],
                        textAlign: TextAlign.center,
                        // La ligne garde sa hauteur fixe : un commentaire long
                        // est elague au lieu de deborder de la cellule.
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: kSerif,
                          fontSize: (13 * MiseEnPage.depuis(context).k).clamp(10.0, 13.0),
                          color: AppColors.ink,
                        ),
                      ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Affiche la photo prise pour une ligne.
///
/// Les octets sont conserves en base (colonne `lignes.photo`) et repartent
/// avec l'evenement LINE_ADD : la photo survit donc a l'arret de
/// l'application et part en ligne comme le reste du formulaire. Une ligne
/// sans octets (pas de photo, ou photo saisie sur un autre poste) est
/// signalee au lieu d'afficher un cadre vide.
void _voirPhoto(BuildContext context, LigneBlast ligne) {
  final Uint8List? octets = ligne.photo;

  showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Photo ${ligne.idDt}'),
      content: octets == null
          ? const SizedBox(
              width: 280,
              child: Text(
                'Aucune image enregistree sur ce poste pour cette ligne.',
                style: TextStyle(fontSize: 15, color: AppColors.slate),
              ),
            )
          : Image.memory(
              octets,
              width: 320,
              fit: BoxFit.contain,
              gaplessPlayback: true,
              errorBuilder: (context, error, stack) => const Text(
                'Image illisible.',
                style: TextStyle(color: AppColors.slate),
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

class _AddStrip extends StatelessWidget {
  const _AddStrip({required this.onAdd});

  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) {
    // La strip entiere est cliquable : un carre de 34x26 est trop petit pour
    // un doigt de chantier (48 dp recommandes), la bande pleine largeur
    // l'autorise sans agrandir le dessin.
    final double k = MiseEnPage.depuis(context).k;
    return InkWell(
      onTap: onAdd,
      child: Container(
        color: AppColors.tan,
        constraints: BoxConstraints(
          maxHeight: (36 * k).clamp(26.0, 36.0),
        ),
        height: double.infinity,
        child: Center(
          child: Container(
            width: (30 * k).clamp(24.0, 30.0),
            height: (24 * k).clamp(20.0, 24.0),
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: AppColors.border),
            ),
            child: Icon(
              Icons.add,
              size: (16 * k).clamp(12.0, 16.0),
              color: onAdd == null ? AppColors.border : AppColors.ink,
            ),
          ),
        ),
      ),
    );
  }
}

/// Bloc de selection, avec son titre (`Select blast`, `Select bloc`) visible
/// meme une valeur choisie.
///
/// En mode [lectureSeule] (`Afficher map`), le bloc n'a pas de menu ni de
/// chevron : la valeur est deja choisie ailleurs, le tap ouvre un apercu
/// (voir [_SpotterScreenState._afficherCarte]) plutot qu'une liste.
class _FilterButton extends StatelessWidget {
  const _FilterButton({
    required this.titre,
    this.onTap,
    this.valeur,
    this.detail,
    this.lectureSeule = false,
    this.apercu,
  });

  final String titre;
  final String? valeur;
  final String? detail;

  /// Ouvre la liste. En mode lecture seule c'est l'apercu de la carte.
  final VoidCallback? onTap;

  /// La valeur est celle du blast, deja chargee : rien a selectionner, donc
  /// pas de menu, pas de chevron, et pas de grise meme quand le blast est
  /// ferme (consulter la carte reste toujours possible).
  final bool lectureSeule;

  /// Plan JPG du blast courant, affiche en vignette dans le bloc.
  final String? apercu;

  @override
  Widget build(BuildContext context) {
    // Pas d'`Expanded` ici : c'est le rang (large ou etroit) qui donne sa
    // largeur au bouton, sinon le meme widget ne peut plus passer d'un rang
    // a l'autre.
    return InkWell(
      onTap: onTap,
      child: LayoutBuilder(
        builder: (context, contraintes) {
          // La vignette cote a cote pese 68 px fixes : des qu'un rang
          // etroit ne lui laisse plus de place, elle disparait et le texte
          // garde le bouton pour lui.
          final bool vignette =
              apercu != null && contraintes.maxWidth >= 170;

          return Container(
            height: (50 * MiseEnPage.depuis(context).k).clamp(38.0, 50.0),
            decoration: BoxDecoration(
              border: Border.all(color: AppColors.border, width: 1.5),
              color: Colors.white,
            ),
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(
              children: [
                if (vignette) ...[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: SizedBox(
                      width: 48,
                      height: 34,
                      child: _ImagePlan(chemin: apercu!, fit: BoxFit.cover),
                    ),
                  ),
                  const SizedBox(width: 12),
                ],
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        titre,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: kSerif,
                          fontSize: (12 * MiseEnPage.depuis(context).k).clamp(9.0, 12.0),
                          letterSpacing: 0.5,
                          color: AppColors.slate,
                        ),
                      ),
                      if (valeur != null)
                        Text(
                          valeur!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: kSerif,
                            fontSize: (15 * MiseEnPage.depuis(context).k).clamp(11.0, 15.0),
                            color: AppColors.ink,
                          ),
                        ),
                    ],
                  ),
                ),
                if (detail != null)
                  Flexible(
                    child: Text(
                      detail!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: kSerif,
                        fontSize: (11 * MiseEnPage.depuis(context).k).clamp(9.0, 11.0),
                        color: AppColors.greyText,
                      ),
                    ),
                  ),
                // Pas de chevron sur un bloc qui n'ouvre aucun menu : le
                // chevron annonce une liste deroulante.
                // Le chevron annonce une liste deroulante. En lecture seule,
                // le bouton ouvre un apercu : on met l'icone d'agrandissement.
                if (lectureSeule)
                  const Icon(
                    Icons.fullscreen,
                    size: 26,
                    color: AppColors.slate,
                  )
                else
                  const Icon(
                    Icons.keyboard_arrow_down,
                    size: 28,
                    color: AppColors.ink,
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Bouton « Envoyer » : transmet au point d'acces les donnees deja
/// enregistrees, donc uniquement sur un blast verrouille.
///
/// Une fois l'envoi fait, le bouton passe en « Envoye » et se fige : il ne
/// redevient actif que si le blast est rouvert, puis de nouveau verrouille.
class _SendButton extends StatelessWidget {
  const _SendButton({
    required this.pret,
    required this.envoye,
    required this.onTap,
  });

  /// Vrai quand les donnees sont pretes : blast verrouille et non vide.
  final bool pret;

  /// Vrai des que la transmission a reussi.
  final bool envoye;

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final bool actif = pret && !envoye;
    final Color encre = envoye
        ? AppColors.green
        : actif
            ? AppColors.ink
            : AppColors.greyText;

    // Comme les filtres : la largeur vient du rang, pas d'ici.
    return InkWell(
      onTap: onTap,
      child: Container(
        height: (50 * MiseEnPage.depuis(context).k).clamp(38.0, 50.0),
        decoration: BoxDecoration(
          border: Border.all(color: AppColors.border, width: 1.5),
          color: actif ? Colors.white : AppColors.greyBg,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Row(
          children: [
            Expanded(
              child: Center(
                // Le libelle est espaces comme la maquette, mais il tient
                // dans un bloc plus etroit que Lock : on le reduit plutot
                // que de deborder.
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    (envoye ? 'Envoye' : 'Envoyer').spaced,
                    style: TextStyle(
                      fontFamily: kSerif,
                      fontSize: (15 * MiseEnPage.depuis(context).k).clamp(11.0, 15.0),
                      letterSpacing: 3,
                      color: encre,
                    ),
                  ),
                ),
              ),
            ),
            Icon(
              envoye
                  ? Icons.check_circle_outline
                  : Icons.upload_outlined,
              size: 24,
              color: encre,
            ),
          ],
        ),
      ),
    );
  }
}

class _LockButton extends StatelessWidget {
  const _LockButton({
    required this.verrouille,
    required this.onTap,
    this.numero,
  });

  final bool verrouille;
  final String? numero;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // Comme les filtres : la largeur vient du rang, pas d'ici.
    return InkWell(
      onTap: onTap,
      child: Container(
        height: (50 * MiseEnPage.depuis(context).k).clamp(38.0, 50.0),
        decoration: BoxDecoration(
          border: Border.all(color: AppColors.border, width: 1.5),
          color: verrouille ? AppColors.slate : Colors.white,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Row(
          children: [
            Expanded(
              child: Center(
                child: Text(
                  'Lock'.spaced,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: kSerif,
                    fontSize: (15 * MiseEnPage.depuis(context).k).clamp(11.0, 15.0),
                    letterSpacing: 3,
                    color: verrouille ? Colors.white : AppColors.ink,
                  ),
                ),
              ),
            ),
            Icon(
              verrouille ? Icons.lock : Icons.lock_open,
              size: 24,
              color: verrouille ? Colors.white : AppColors.ink,
            ),
          ],
        ),
      ),
    );
  }
}

/// Bouton de relecture (Captures / Historique / Compte-rendu) : style des
/// autres blocs d'action de l'ecran (bordure 1.5 px, serif), hauteur plus
/// faible — ce sont des acces secondaires, pas des boutons de saisie.
class _BoutonRelire extends StatelessWidget {
  const _BoutonRelire({
    required this.icone,
    required this.libelle,
    required this.onTap,
    required this.compact,
  });

  final IconData icone;
  final String libelle;
  final VoidCallback onTap;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final double k = MiseEnPage.depuis(context).k;
    return InkWell(
      onTap: onTap,
      child: Container(
                        height: compact ? 30 : 40,
                        decoration: BoxDecoration(
          border: Border.all(color: AppColors.border, width: 1.5),
          color: Colors.white,
        ),
        padding: EdgeInsets.symmetric(horizontal: 12 * k),
        child: Row(
          children: [
            Icon(icone, size: 20 * k, color: AppColors.slate),
            SizedBox(width: 10 * k),
            Expanded(
              child: Text(
                libelle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: kSerif,
                  fontSize: (13 * k).clamp(10.0, 13.0),
                  color: AppColors.ink,
                ),
              ),
            ),
            Icon(Icons.chevron_right, size: 20 * k, color: AppColors.border),
          ],
        ),
      ),
    );
  }
}



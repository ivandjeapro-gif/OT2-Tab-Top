import 'package:flutter/material.dart';

import '../data/base_locale.dart';
import '../models/models.dart';
import '../state/session.dart';
import '../theme/app_theme.dart';
import '../theme/responsive.dart';
import '../widgets/app_header.dart';
import 'dt_screen.dart';
import 'excavator_screen.dart';
import 'parametres_screen.dart';
import 'spotter_screen.dart';

/// Ecran d'accueil : choix du profil + identifiants de connexion.
///
/// Deux presentations, pilotees par MiseEnPage :
/// - sur grand ecran, les deux colonnes sont cote a cote ;
/// - sur telephone/tablette en portrait, elles s'empilent.
///
/// Aucune zone ne defile : la page tient toujours dans la hauteur visible.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.session});

  final Session session;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  /// Profil choisi, lu dans `base.profils()` (CDC §2.3) : rien n'est ecrit
  /// en dur ici, la base decide de la liste et de leur ordre.
  Profil? _profil;
  String? _id;
  String? _name;

  /// Famille choisie (machines : DT/EXCAVATOR). Null pour les personnes.
  String? _famille;

  /// Équipe choisie (personnes : SPOT). Le menu 2 liste les noms de l'equipe.
  String? _equipe;

  @override
  void initState() {
    super.initState();
    final List<Profil> profils = widget.session.base.profilsActifs;
    // Verrouillage de role (PARAMETRES.md) : si cette tablette a deja porte
    // un role (`role_verrouille`), on le re-selectionne au demarrage — l'oper
    // rateur retrouve d'emblée le bon écran, sans re-apprendre le profil.
    final String verrou = (widget.session.base.meta('role_verrouille') ?? '').trim();
    _profil = profils.isEmpty
        ? null
        : (verrou.isNotEmpty
            ? profils.firstWhere(
                (Profil p) => p.roleCdc == verrou,
                orElse: () => profils.first,
              )
            : profils.first);
    widget.session.addListener(_surSession);
  }

  @override
  void dispose() {
    widget.session.removeListener(_surSession);
    super.dispose();
  }

  void _surSession() {
    if (!mounted) return;
    final List<Profil> profils = widget.session.base.profilsActifs;
    setState(() {
      if (_profil == null && profils.isNotEmpty) {
        // Reprise du verrou si present, sinon le premier profil actif.
        final String verrou = (widget.session.base.meta('role_verrouille') ?? '').trim();
        _profil = verrou.isNotEmpty
            ? profils.firstWhere(
                (Profil p) => p.roleCdc == verrou,
                orElse: () => profils.first,
              )
            : profils.first;
      }
    });
  }

  void _choisirProfil(Profil profil) {
    // Verrouillage de role (PARAMETRES.md) : une tablette qui a deja porte un
    // role (`role_verrouille` dans `meta`) refuse silencieusement un autre
    // role sauf confirmation explicite — cela evite qu'une erreur d'appui
    // remonte les couches BLE / Wi-Fi Direct de la session.
    final String? verrou = widget.session.base.meta('role_verrouille');
    if (verrou != null && verrou != profil.roleCdc) {
      _demanderDeverrouillage(profil);
      return;
    }
    setState(() {
      _profil = profil;
      _id = null;
      _name = null;
      _famille = null;
      _equipe = null;
    });
  }

  /// Dialogue de confirmation avant de changer le role verrouille.
  Future<void> _demanderDeverrouillage(Profil profil) async {
    final bool? confirme = await showDialog<bool>(
      context: context,
      builder: (BuildContext contexte) => AlertDialog(
        title: const Text('Changer de role ?'),
        content: Text(
          'Cette tablette est verrouillee sur un autre role. '
          'Voulez-vous vraiment la passer en « ${profil.libelle} » ?',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(contexte).pop(false),
            child: const Text('Annuler'),
          ),
          TextButton(
            onPressed: () => Navigator.of(contexte).pop(true),
            child: const Text('Changer'),
          ),
        ],
      ),
    );
    if (confirme != true || !mounted) return;
    // Le role change : on efface tout l'etat BLE / Wi-Fi Direct (groupes,
    // advertising, connexions TCP) pour que la nouvelle role redemarre sur des
    // couches propres — jamais de restes de l'ancienne configuration.
    widget.session.disconnect();
    // Le verrou suit le nouveau role choisi (la connexion le re-pose aussi).
    await widget.session.base.majMeta('role_verrouille', profil.roleCdc);
    setState(() {
      _profil = profil;
      _id = null;
      _name = null;
      _famille = null;
      _equipe = null;
    });
  }

  void _choisirMenu1(String? valeur) {
    setState(() {
      // Famille (machines) ou Equipe (spotter) : le changement invalide le
      // second choix, qui n'appartient peut-etre plus a la nouvelle valeur.
      if (BaseLocale.estTab1(_profil?.roleCdc ?? '')) {
        _equipe = valeur;
      } else {
        _famille = valeur;
      }
      _id = null;
      _name = null;
    });
  }

  Future<void> _connecter() async {
    final Profil? profil = _profil;
    if (profil == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Aucun profil disponible.')),
      );
      return;
    }
    if (_id == null || _name == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Selectionnez votre identifiant et votre nom.'),
        ),
      );
      return;
    }
    // Les deux menus sont independants (maquette Connexion) : c'est le seul
    // endroit ou l'on refuse un couple qui ne designerait pas un seul et meme
    // equipement. La base decide, l'ecran n'invente rien (REQ-002).
    final String? attendu =
        widget.session.base.nomDuProfil(profil, _id!);
    if (attendu == null || attendu != _name) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Identifiant et nom ne designent pas le meme equipement.',
          ),
        ),
      );
      return;
    }
    // Defense en profondeur : on a change de profil depuis la selection de
    // l'ID (race theorique : un autre widget appelle setState). Si l'ID ne
    // fait plus partie du profil courant, on refuse plutot que d'envoyer une
    // combinaison absurde a la session.
    if (!widget.session.base.idsDuProfil(profil).contains(_id!)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Selectionnez un identifiant compatible avec le profil.'),
        ),
      );
      return;
    }
    // La validite du login vient des referentiels locaux, pas de l'etat Wi-Fi
    // (une tablette hors ligne doit pouvoir ouvrir son profil).
    final bool connecte =
        widget.session.connect(selected: profil, id: _id!, name: _name!);
    if (!connecte) {
      final String motif = widget.session.base.refusEnCours ??
          'Connexion refusee : referentiels serveur manquants ou obsoletes';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(motif)),
      );
      return;
    }

    // Connexion reussie : la tablette est desormais verrouillee sur ce role.
    // Au prochain demarrage, ce role sera pre-selectionne et un autre choix
    // demandera une confirmation (voir _choisirProfil).
    if (widget.session.base.meta('role_verrouille') != profil.roleCdc) {
      await widget.session.base.majMeta('role_verrouille', profil.roleCdc);
    }

    // L'ecran suit le role CDC du profil (REQ-002) : TAB 2 = spotter,
    // TAB 3 = excavatrice, TAB 1 = DT. Le libelle, lui, vient de la table.
    final Widget ecran = BaseLocale.estTab2(profil.roleCdc)
        ? DtScreen(session: widget.session)
        : BaseLocale.estTab3(profil.roleCdc)
            ? ExcavatorScreen(session: widget.session)
            : SpotterScreen(session: widget.session);

    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(builder: (_) => ecran),
    );
  }

  /// Vrai pendant l'actualisation manuelle : le bouton affiche un spinner
  /// et refuse les appuis rapproches (meme garde-fou que Session).
  bool _actualisationEnCours = false;

  @override
  Widget build(BuildContext context) {
    final MiseEnPage mise = MiseEnPage.depuis(context);

    // Acces aux cles `meta` (PARAMETRES.md §7) : preparer une tablette ne
    // demande aucune connexion, le bouton vit donc sur cet ecran.
    //
    // Le `Transform.translate` decale le bouton vers la droite pour
    // annuler le `margeHorizontale` du Padding parent (32 px quand
    // largeur > 600, 18 sinon) et le coller au bord reel de l'ecran.
    // On utilise une translation plutot qu'un padding negatif pour
    // eviter l'assertion `padding.isNonNegative` levee depuis
    // `shifted_box.dart:117`.
    final double decalageDroitBoutonParametres =
        (MediaQuery.sizeOf(context).width > 600 ? 32.0 : 18.0) - 4;
    // Bouton « Actualiser » : relance une passe complete de synchronisation
    // (referentiels, blasts, affectation, notifications). Il permet de
    // remplir les listes de connexion juste apres avoir saisi api_base /
    // api_token dans Parametres, sans redemarrer l'application.
    // Le deuxieme bouton est colle au bord via le meme decalage.
    // Les deux boutons se replient sur deux lignes quand la largeur manque.
    //
    // Le `Transform.translate` qui les colle au bord decalait la ligne de
    // 28 px vers la droite : sur un ecran etroit (telephone), cette ligne
    // depassait son parent de 30 px et Flutter la signalait comme rognee.
    // Un `Wrap` laisse les boutons passer a la ligne au lieu de deborder.
    final Widget boutons = Align(
      alignment: Alignment.centerRight,
      child: Transform.translate(
        offset: Offset(decalageDroitBoutonParametres, 0),
        child: Wrap(
          alignment: WrapAlignment.end,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            TextButton.icon(
              key: const ValueKey<String>('bouton-actualiser'),
              onPressed: _actualisationEnCours
                  ? null
                  : () async {
                      setState(() => _actualisationEnCours = true);
                      try {
                        await widget.session.synchro.unePasseReferentiels(forcer: true);
                        await widget.session.synchroniserManuellement();
                      } finally {
                        if (mounted) {
                          final List<Profil> profils =
                              widget.session.base.profilsActifs;
                          setState(() {
                            _actualisationEnCours = false;
                            if (_profil == null && profils.isNotEmpty) {
                              _profil = profils.first;
                            }
                          });
                        }
                      }
                    },
              icon: _actualisationEnCours
                  ? SizedBox(
                      width: 16, height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.slate),
                    )
                  : const Icon(Icons.refresh, size: 20, color: AppColors.slate),
              label: Text(
                _actualisationEnCours ? 'Actualisation...' : 'Actualiser',
                style: TextStyle(
                  fontSize: (15 * mise.k).clamp(12.0, 15.0),
                  fontWeight: FontWeight.w700,
                  color: AppColors.slate,
                ),
              ),
            ),
            TextButton.icon(
              key: const ValueKey<String>('bouton-parametres'),
              onPressed: () async {
                await Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => ParametresScreen(session: widget.session),
                  ),
                );
                if (mounted) {
                  final List<Profil> profils = widget.session.base.profilsActifs;
                  setState(() {
                    if (_profil == null && profils.isNotEmpty) {
                      _profil = profils.first;
                    }
                  });
                }
              },
              icon: const Icon(Icons.settings, size: 20, color: AppColors.slate),
              label: Text(
                'Parametres',
                style: TextStyle(
                  fontSize: (15 * mise.k).clamp(12.0, 15.0),
                  fontWeight: FontWeight.w700,
                  color: AppColors.slate,
                ),
              ),
            ),
          ],
        ),
      ),
    );

    // Boutons de profil lus dans la table `profils` (§2.3), jamais dans le
    // code : ajouter un profil revient a ajouter une ligne.
    final List<Profil> profils = widget.session.base.profilsActifs;
    final Widget colonneProfils = _ProfilePicker(
      profils: profils,
      profil: _profil,
      surChangement: _choisirProfil,
      mise: mise,
      compactPortrait: MiseEnPage.estCompactPortrait(context),
    );
    // Serveur final : TOUS les profils ont DEUX menus dependants, servis
    // par la base — jamais par le code :
    //  - machines (DT, EXCAVATOR) : menu 1 = FAMILLE (colonne `role` de la
    //    flotte), menu 2 = Identifiant unique (numero de la famille) ;
    //  - personnes (SPOT)          : menu 1 = EQUIPE (colonne `equipe` des
    //    identifiants), menu 2 = Nom (membres de l'equipe).
    final bool estSpotter = _profil != null &&
        BaseLocale.estTab1(_profil!.roleCdc);
    final List<String> elementsMenu1 = _profil == null
        ? const <String>[]
        : (estSpotter
            ? widget.session.base.equipesDuProfil(_profil!)
            : widget.session.base.famillesDuProfil(_profil!));
    final String? valeurMenu1 = estSpotter ? _equipe : _famille;
    final List<String> ids = _profil == null
        ? const <String>[]
        : (estSpotter && _equipe != null
            ? widget.session.base.idsDEquipe(_profil!, _equipe!)
            : (_famille != null && !estSpotter
                ? widget.session.base.idsDuFamille(_profil!, _famille!)
                : widget.session.base.idsDuProfil(_profil!)));
    final List<String> noms = _profil == null
        ? const <String>[]
        : (estSpotter && _equipe != null
            ? widget.session.base.nomsDEquipe(_profil!, _equipe!)
            : (_famille != null && !estSpotter
                ? widget.session.base.nomsDeFamille(_profil!, _famille!)
                : widget.session.base.nomsDuProfil(_profil!)));

    final Widget colonneIdentifiants = _Credentials(
      // Serveur final : DEUX menus dependants pour tous les profils.
      // Machine : Famille -> Identifiant ; Spotter : Equipe -> Nom.
      libelleMenu1: estSpotter ? 'Equipe' : 'Famille',
      valeurMenu1: valeurMenu1,
      elementsMenu1: elementsMenu1,
      surMenu1: _choisirMenu1,
      libelleMenu2: estSpotter ? 'Nom' : 'Identifiant unique',
      champIdentifiant: !estSpotter,
      ids: ids,
      noms: noms,
      id: _id,
      nom: _name,
      surId: (v) => setState(() {
        // L'UI manipule le NUMERO SEUL (menu 2) ; la session recoit l'ID
        // COMPOSE (famille-numero), cle des equipements. Sans ce resolver,
        // la validation du couple refusait un numero qui existe pourtant.
        final String? compose = (_profil != null && _famille != null)
            ? widget.session.base.idDeFamille(_profil!, _famille!, v ?? '')
            : null;
        _id = compose ?? v;
        if (_profil != null && _id != null) {
          _name = widget.session.base.nomDuProfil(_profil!, _id!) ?? _name;
        }
      }),
      surNom: (v) => setState(() {
        _name = v;
        if (_profil != null && v != null) {
          final String? idResolu = estSpotter && _equipe != null
              ? widget.session.base.idDeEquipe(_profil!, _equipe!, v)
              : widget.session.base.idDuProfil(_profil!, v);
          _id = idResolu ?? _id;
        }
      }),
      surConnexion: _connecter,
      mise: mise,
      compactPortrait: MiseEnPage.estCompactPortrait(context),
    );

    return Scaffold(
      backgroundColor: AppColors.paper,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: LayoutBuilder(
                builder: (context, contraintesPage) {
                  final double hauteurUtile = contraintesPage.maxHeight;
                  // Regle unique, exposee par MiseEnPage : evitent les trois
                  // predictions divergentes (cf. fix #3 de l'audit).
                  final bool portraitCompact = MiseEnPage.estCompactPortrait(context) ||
                      hauteurUtile < 720;
                  final double maxLargeur = contraintesPage.maxWidth > 760
                      ? 920
                      : contraintesPage.maxWidth;
                  final double margeHorizontale =
                      contraintesPage.maxWidth > 600 ? 32 : 18;
                  final double margeVerticale = portraitCompact ? 10 : 20;

                  // Aucun defilement : le contenu est centre, jamais scrolle.
                  return Center(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: maxLargeur),
                      child: Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: margeHorizontale,
                          vertical: margeVerticale,
                        ),
                        child: _LoginBody(
                          mise: mise,
                          portraitCompact: portraitCompact,
                          hauteurUtile: hauteurUtile,
                          boutonParametres: boutons,
                          profils: colonneProfils,
                          identifiants: colonneIdentifiants,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            AppFooter(mise: mise),
          ],
        ),
      ),
    );
  }
}

/// Corps central de l'ecran de connexion : logo, titre et la zone des deux
/// colonnes (profils + identifiants) en cote-a-cote ou empilees selon la
/// disposition decidee par [MiseEnPage].
///
/// Extrait du build de `_LoginScreenState` pour rendre la methode principale
/// lisible et faciliter le test visuel des deux variantes.
class _LoginBody extends StatelessWidget {
  const _LoginBody({
    required this.mise,
    required this.portraitCompact,
    required this.hauteurUtile,
    required this.boutonParametres,
    required this.profils,
    required this.identifiants,
  });

  final MiseEnPage mise;
  final bool portraitCompact;
  final double hauteurUtile;
  final Widget boutonParametres;
  final Widget profils;
  final Widget identifiants;

  @override
  Widget build(BuildContext context) {
    // Le contenu defile au lieu de deborder.
    //
    // Sur un telephone (Tecno, portrait etroit), logo + titre + deux blocs +
    // bouton depassent la hauteur disponible : sans defilement, Flutter
    // signalait « RenderFlex overflowed by 134 pixels » et coupait le bas de
    // l'ecran. Le `Center` garde le centrage quand tout tient, et le
    // `SingleChildScrollView` prend le relais quand ce n'est plus le cas.
    return Center(
      child: SingleChildScrollView(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: boutonParametres,
        ),
        SizedBox(
          height: portraitCompact ? 90 : mise.hauteurLogo,
          child: Image.asset(
            'assets/images/logo_ore_tracking.png',
            fit: BoxFit.contain,
          ),
        ),
        SizedBox(height: portraitCompact ? 8 : mise.ecartTitre),
        Text(
          'Welcome here, select your profil',
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: portraitCompact ? 24 : mise.policeTitre.clamp(22.0, 32.0),
            fontWeight: FontWeight.w800,
            letterSpacing: portraitCompact ? 0.6 : 1.0 * mise.k,
            color: AppColors.ink,
          ),
        ),
        SizedBox(height: portraitCompact ? 18 : mise.ecartSection),
        ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: portraitCompact ? 500 : double.infinity,
          ),
          child: mise.aEmpile
              ? _StackedBody(
                  profils: profils,
                  identifiants: identifiants,
                  mise: mise,
                  compactPortrait: portraitCompact,
                )
              : _SideBySideBody(
                  profils: profils,
                  identifiants: identifiants,
                  mise: mise,
                  hauteurUtile: hauteurUtile,
                ),
        ),
          ],
        ),
      ),
    );
  }
}

/// Deux colonnes alignees sur une meme ligne, sans filet vertical.
class _SideBySideBody extends StatelessWidget {
  const _SideBySideBody({
    required this.profils,
    required this.identifiants,
    required this.mise,
    required this.hauteurUtile,
  });

  final Widget profils;
  final Widget identifiants;
  final MiseEnPage mise;
  final double hauteurUtile;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: (hauteurUtile - 260).clamp(220.0, 600.0),
      ),
      child: Row(
        children: [
          Expanded(child: profils),
          SizedBox(width: mise.ecartElement),
          Expanded(child: identifiants),
        ],
      ),
    );
  }
}

/// Variante empilee : le wrapper choisit entre cote-a-cote et empile en
/// fonction de [MiseEnPage.aEmpile]. La separation visuelle entre les deux
/// blocs est assuree par [_ColonnesEmpilees].
class _StackedBody extends StatelessWidget {
  const _StackedBody({
    required this.profils,
    required this.identifiants,
    required this.mise,
    required this.compactPortrait,
  });

  final Widget profils;
  final Widget identifiants;
  final MiseEnPage mise;
  final bool compactPortrait;

  @override
  Widget build(BuildContext context) {
    return _ColonnesEmpilees(
      profils: profils,
      identifiants: identifiants,
      mise: mise,
      compactPortrait: compactPortrait,
    );
  }
}

/// Version telephone : une seule colonne, separee par un trait horizontal.
class _ColonnesEmpilees extends StatelessWidget {
  const _ColonnesEmpilees({
    required this.profils,
    required this.identifiants,
    required this.mise,
    this.compactPortrait = false,
  });

  final Widget profils;
  final Widget identifiants;
  final MiseEnPage mise;
  final bool compactPortrait;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        profils,
        SizedBox(height: compactPortrait ? 16 : mise.ecartSection),
        Container(height: 1.5, color: AppColors.ink),
        SizedBox(height: compactPortrait ? 16 : mise.ecartSection),
        identifiants,
      ],
    );
  }
}

class _ProfilePicker extends StatelessWidget {
  const _ProfilePicker({
    required this.profils,
    required this.profil,
    required this.surChangement,
    required this.mise,
    this.compactPortrait = false,
  });

  /// Profils proposes, dans l'ordre de la table `profils`.
  final List<Profil> profils;
  final Profil? profil;
  final ValueChanged<Profil> surChangement;
  final MiseEnPage mise;
  final bool compactPortrait;

  @override
  Widget build(BuildContext context) {
    final Widget contenu = Column(
      mainAxisAlignment: compactPortrait
          ? MainAxisAlignment.center
          : MainAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (profils.isEmpty)
          Text(
            'Aucun profil configure.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: (21 * mise.k).clamp(15.0, 21.0),
              fontWeight: FontWeight.w700,
              color: const Color(0xFF70747A),
            ),
          ),
        for (int i = 0; i < profils.length; i++) ...[
          if (i > 0) SizedBox(height: mise.ecartElement),
          // MEME hauteur que les champs de la colonne d'en face
          // (`mise.hauteurBouton`, borne a 54 px comme `SelectField` et
          // « Connect »). Le mode compact raccourcissait les badges de
          // profil a ~54 px alors que les menus restaient a leur hauteur :
          // les deux colonnes ne s'alignaient plus et les badges de
          // SPOTTER/EXCAVATOR paraissaient plus petits que les autres.
          _ProfileButton(
            key: ValueKey<String>('profil-${profils[i].code}'),
            libelle: profils[i].libelle,
            selectionne: profils[i] == profil,
            surAppui: () => surChangement(profils[i]),
            hauteur: mise.hauteurBouton < 54 ? 54 : mise.hauteurBouton,
            police: (21 * mise.k).clamp(15.0, 21.0),
          ),
        ],
      ],
    );

    if (mise.aEmpile) {
      return Padding(
        padding: EdgeInsets.symmetric(
          vertical: compactPortrait ? 2 : mise.margeColonne.vertical,
        ),
        child: contenu,
      );
    }

    // Aucun defilement : le contenu est centre dans la colonne.
    return Padding(
      padding: mise.margeColonne,
      child: Center(child: contenu),
    );
  }
}

class _ProfileButton extends StatelessWidget {
  const _ProfileButton({
    super.key,
    required this.libelle,
    required this.selectionne,
    required this.surAppui,
    required this.hauteur,
    required this.police,
  });

  final String libelle;
  final bool selectionne;
  final VoidCallback surAppui;
  final double hauteur;
  final double police;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selectionne ? AppColors.slate : AppColors.greyButton,
      child: InkWell(
        onTap: surAppui,
        child: Container(
          constraints: const BoxConstraints(minHeight: 54),
          height: hauteur < 54 ? 54 : hauteur,
          alignment: Alignment.center,
          child: Text(
            libelle,
            style: TextStyle(
              fontSize: police,
              fontWeight: FontWeight.w700,
              color: selectionne ? Colors.white : const Color(0xFF70747A),
            ),
          ),
        ),
      ),
    );
  }
}

class _Credentials extends StatelessWidget {
  const _Credentials({
    required this.libelleMenu1,
    required this.valeurMenu1,
    required this.elementsMenu1,
    required this.surMenu1,
    required this.libelleMenu2,
    required this.ids,
    required this.noms,
    required this.id,
    required this.nom,
    required this.surId,
    required this.surNom,
    required this.surConnexion,
    required this.mise,
    this.champIdentifiant = true,
    this.compactPortrait = false,
  });

  /// Menu 1 (dependance) : Famille pour les machines, Equipe pour le spotter.
  final String libelleMenu1;
  final String? valeurMenu1;
  final List<String> elementsMenu1;
  final ValueChanged<String?> surMenu1;

  /// Menu 2 : Identifiant unique (machines) ou Nom (spotter).
  final String libelleMenu2;

  /// Vrai si le menu 2 est un IDENTIFIANT machine (deduit le nom du couple).
  /// Pour le spotter, le menu 2 EST deja un nom — pas de troisieme champ.
  final bool champIdentifiant;

  /// Valeur AFFICHEE par le menu 2 : le numero seul extrait de l'ID compose
  /// (`EX-2000` -> `2000`, `1500-1` -> `1`). Le DropdownButton n'accepte que
  /// des valeurs presentes dans `ids` ; l'ID compose reste la verite stockee
  /// et transmise a la session.
  String? get valeurIdAffichee {
    if (id == null) return null;
    if (!champIdentifiant) return nom;
    if (ids.contains(id)) return id;
    final int i = id!.indexOf('-');
    return i >= 0 ? id!.substring(i + 1) : id;
  }

  /// Identifiants et noms du role choisi, tous deux lus dans la base.
  ///
  /// Meme longueur, meme ordre : les deux menus presentent les lignes de la
  /// meme table, et c'est [BaseLocale.nomDu] qui valide le couple au moment
  /// de la connexion.
  final List<String> ids;
  final List<String> noms;
  final String? id;
  final String? nom;
  final ValueChanged<String?> surId;
  final ValueChanged<String?> surNom;
  final VoidCallback surConnexion;
  final MiseEnPage mise;
  final bool compactPortrait;

  @override
  Widget build(BuildContext context) {
    final Widget contenu = Column(
      mainAxisAlignment: compactPortrait
          ? MainAxisAlignment.center
          : MainAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        SelectField(
          key: const ValueKey<String>('champ-menu1'),
          indice: libelleMenu1,
          valeur: valeurMenu1,
          elements: elementsMenu1,
          surChangement: surMenu1,
          mise: mise,
        ),
        SizedBox(height: compactPortrait ? 10 : mise.ecartElement),
        // Serveur final : DEUX champs par profil, pas trois. Pour les
        // machines, le nom est deduit de l'identifiant (le menu 2 du spotter
        // EST le nom) — un troisieme champ ne ferait que deborder sur les
        // ecrans paysage bas (844x390...).
        if (champIdentifiant) ...[
          SelectField(
            key: const ValueKey<String>('champ-id'),
            indice: libelleMenu2,
            // AFFICHAGE = numero seul. `id` porte l'ID COMPOSE (famille-numero)
            // et ne figure pas dans `ids` (numeros seuls) : le passer tel quel
            // levait l'assertion Flutter « value must appear in items ».
            valeur: valeurIdAffichee,
            elements: ids,
            surChangement: surId,
            mise: mise,
          ),
        ] else ...[
          SelectField(
            key: const ValueKey<String>('champ-nom'),
            indice: libelleMenu2,
            valeur: nom,
            elements: noms,
            surChangement: surNom,
            mise: mise,
          ),
        ],
        SizedBox(height: compactPortrait ? 10 : mise.ecartElement),
        // Largeur bornee par la colonne : `largeurBouton` plafonne le bouton,
        // mais sur un ecran plus etroit que cette valeur, le bouton prend la
        // largeur disponible au lieu de deborder de la colonne.
        ConstrainedBox(
          key: const ValueKey<String>('bouton-connexion'),
          constraints: BoxConstraints(
            maxWidth: mise.largeurBouton,
            minHeight: compactPortrait
                ? 54
                : (mise.hauteurBouton < 54 ? 54 : mise.hauteurBouton),
            maxHeight: compactPortrait
                ? 54
                : (mise.hauteurBouton < 54 ? 54 : mise.hauteurBouton),
          ),
          child: Material(
            color: AppColors.slate,
            child: InkWell(
              onTap: surConnexion,
              child: Container(
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  'Connect',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: (24 * mise.k).clamp(16.0, 24.0),
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );

    if (mise.aEmpile) {
      return Padding(
        padding: EdgeInsets.symmetric(
          vertical: compactPortrait ? 2 : mise.margeColonne.vertical,
        ),
        child: contenu,
      );
    }

    // Aucun defilement : le contenu est centre dans la colonne.
    return Padding(
      padding: mise.margeColonne,
      child: Center(child: contenu),
    );
  }
}

/// Champ de selection encadre avec chevron (maquette Connexion).
class SelectField extends StatelessWidget {
  const SelectField({
    super.key,
    required this.indice,
    required this.elements,
    required this.surChangement,
    required this.mise,
    this.valeur,
  });

  final String indice;
  final String? valeur;
  final List<String> elements;
  /// Callback appele uniquement avec une valeur reelle (jamais `null`).
  ///
  /// Le [DropdownButton] sous-jacent peut theoriquement appeler `onChanged`
  /// avec `null` quand la liste change, mais en pratique la liste est figee
  /// pendant la duree de vie du widget : on filtre donc ce cas pour exposer
  /// une signature non-null, plus sure pour les appelants.
  final ValueChanged<String> surChangement;
  final MiseEnPage mise;

  @override
  Widget build(BuildContext context) {
    // Taille de police bornee, calculee une seule fois par build : on la
    // partage entre l'indice, la valeur selectionnee et les items du dropdown,
    // ce qui supprime la duplication d'origine (cf. fix #6 de l'audit).
    final double fontSize = (19 * mise.k).clamp(14.0, 19.0);
    final TextStyle baseStyle = TextStyle(
      fontSize: fontSize,
      decoration: TextDecoration.underline,
    );
    final TextStyle styleIndice = baseStyle.copyWith(
      color: const Color(0xFF8A8D91),
    );
    final TextStyle styleValeur = baseStyle.copyWith(color: AppColors.ink);
    final TextStyle styleItem = TextStyle(fontSize: fontSize);

    return Container(
      constraints: BoxConstraints(
        minHeight: mise.hauteurBouton < 54 ? 54 : mise.hauteurBouton,
      ),
      height: mise.hauteurBouton < 54 ? 54 : mise.hauteurBouton,
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.border, width: 1.5),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          Expanded(
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: valeur,
                isExpanded: true,
                alignment: Alignment.center,
                icon: const SizedBox.shrink(),
                hint: Center(child: Text(indice, style: styleIndice)),
                selectedItemBuilder: (context) => [
                  for (final element in elements)
                    Center(child: Text(element, style: styleValeur)),
                ],
                items: [
                  for (final element in elements)
                    DropdownMenuItem<String>(
                      value: element,
                      child: Center(
                        child: Text(element, style: styleItem),
                      ),
                    ),
                ],
                onChanged: (String? v) {
                  if (v != null) {
                    surChangement(v);
                  }
                },
              ),
            ),
          ),
          Icon(
            Icons.keyboard_arrow_down,
            size: (30 * mise.k).clamp(20.0, 30.0),
          ),
        ],
      ),
    );
  }
}

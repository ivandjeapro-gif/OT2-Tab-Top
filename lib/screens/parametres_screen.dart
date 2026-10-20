import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/base_locale.dart';
import '../data/transmetteur.dart';
import '../state/session.dart';
import '../theme/app_theme.dart';
import '../theme/responsive.dart';

/// Ecran « Parametres » (PARAMETRES.md) : la saisie des cles `meta` au lieu
/// du SQL.
///
/// Trois familles de reglages, toutes ecrites par `BaseLocale.majMeta` :
/// 1. **Serveur** (`api_base`, `api_token`) : relus a chaque envoi, donc
///    applicables sans redemarrage ;
/// 2. **Envoi** (`envoi_mode`) : perimetre du bouton « Envoyer » du spotter ;
/// 3. **Detection d'ecart / GPS** (`seuil_entree_m`, `seuil_sortie_m`,
///    `delai_confirmation_s`, `intervalle_gps_s`, `filtre_distance_gps_m`)
///    : appliques par `Session.rechargerParametres` au moment de l'enregistrement.
///
/// Ouvert depuis l'ecran de connexion (PARAMETRES.md §7) : aucune connexion
/// n'est requise pour preparer une tablette.
class ParametresScreen extends StatefulWidget {
  const ParametresScreen({super.key, required this.session});

  final Session session;

  @override
  State<ParametresScreen> createState() => _ParametresScreenState();
}

class _ParametresScreenState extends State<ParametresScreen> {
  Session get session => widget.session;

  late final TextEditingController _apiBase;
  late final TextEditingController _apiToken;
  late final TextEditingController _seuilEntree;
  late final TextEditingController _seuilSortie;
  late final TextEditingController _delai;
  late final TextEditingController _intervalle;
  late final TextEditingController _filtre;

  String _envoiMode = BaseLocale.envoiModeBlast;
  String? _erreur;

  /// Resultat du dernier test de sante du serveur (affiche sous le bouton).
  String? _diagnosticServeur;

  /// Test la chaine complete vers le serveur central Apps Script : lit
  // api_base/api_token TAPES (pas encore enregistres), appelle `?action=sante`
  // et affiche le resultat en vert/rouge sous le bouton.
  Future<void> _testerServeur() async {
    setState(() => _diagnosticServeur = 'Test en cours...');
    final TransmetteurHttp test = TransmetteurHttp(
      meta: (String cle) => switch (cle) {
        'api_base' => _apiBase.text.trim().replaceFirst(RegExp(r'/+$'), ''),
        'api_token' => _apiToken.text.trim(),
        _ => session.base.meta(cle),
      },
    );
    final String resultat = await test.diagnosticSante();
    if (!mounted) return;
    setState(() => _diagnosticServeur = resultat);
    session.push(resultat);
  }

  @override
  void initState() {
    super.initState();
    final BaseLocale base = session.base;
    _apiBase = TextEditingController(text: base.meta('api_base') ?? '');
    _apiToken = TextEditingController(text: base.meta('api_token') ?? '');
    _seuilEntree = TextEditingController(text: base.meta('seuil_entree_m') ?? '40');
    _seuilSortie = TextEditingController(text: base.meta('seuil_sortie_m') ?? '20');
    _delai = TextEditingController(text: base.meta('delai_confirmation_s') ?? '15');
    _intervalle = TextEditingController(text: base.meta('intervalle_gps_s') ?? '5');
    _filtre = TextEditingController(text: base.meta('filtre_distance_gps_m') ?? '5');
    _envoiMode = base.envoiMode;
  }

  @override
  void dispose() {
    _apiBase.dispose();
    _apiToken.dispose();
    _seuilEntree.dispose();
    _seuilSortie.dispose();
    _delai.dispose();
    _intervalle.dispose();
    _filtre.dispose();
    super.dispose();
  }

  /// Valide puis ecrit chaque cle. Une valeur incoherente est refusee avant
  /// toute ecriture : `meta` ne voit jamais un couple de seuils impossible.
  Future<void> _enregistrer() async {
    final double? entree = double.tryParse(_seuilEntree.text.trim());
    final double? sortie = double.tryParse(_seuilSortie.text.trim());
    final int? delai = int.tryParse(_delai.text.trim());
    final int? intervalle = int.tryParse(_intervalle.text.trim());
    final double? filtre = double.tryParse(_filtre.text.trim());

    String? erreur;
    if (entree == null || sortie == null || delai == null) {
      erreur = 'Seuils d\'ecart : nombres attendus (ex. 40, 20, 15).';
    } else if (entree < 10 || entree > 500) {
      erreur = 'Seuil d\'entree : borne 10 a 500 metres.';
    } else if (sortie < 5 || sortie >= entree) {
      erreur =
          'Seuil de sortie : entre 5 et ${entree - 1} m (il doit rester '
          'inferieur au seuil d\'entree).';
    } else if (delai < 0 || delai > 300) {
      erreur = 'Delai de confirmation : borne 0 a 300 secondes.';
    } else if (intervalle == null || intervalle < 1 || intervalle > 300) {
      erreur = 'Intervalle GPS : borne 1 a 300 secondes.';
    } else if (filtre == null || filtre < 0 || filtre > 100) {
      erreur = 'Filtre de distance GPS : borne 0 a 100 metres.';
    }

    if (erreur != null) {
      setState(() => _erreur = erreur);
      return;
    }

    final BaseLocale base = session.base;
    // La racine de l'API se note sans slash final : on l'impose plutot que
    // de laisser TransmetteurHttp construire `https://…/ /affectation`.
    final String apiBase = _apiBase.text.trim().replaceFirst(RegExp(r'/+$'), '');

    await base.majMeta('api_base', apiBase);
    await base.majMeta('api_token', _apiToken.text.trim());
    // Racine de la Web App : sert au repli de `planPourCarte`, qui construit
    // `?action=plan&carte=<code>` pour un RL dont l'URL n'a pas encore ete
    // recue par la synchro. Sans cela, un blast multi-RL retombe sur le plan
    // de sa premiere carte.
    base.poserBaseServeur(apiBase);
    await base.majMeta('envoi_mode', _envoiMode);
    await base.majMeta('seuil_entree_m', entree.toString());
    await base.majMeta('seuil_sortie_m', sortie.toString());
    await base.majMeta('delai_confirmation_s', delai.toString());
    await base.majMeta('intervalle_gps_s', intervalle.toString());
    await base.majMeta('filtre_distance_gps_m', filtre.toString());

    // Seuils + GPS appliques en direct (api_* et envoi_mode sont relus a
    // chaque envoi, ils n'ont pas besoin d'etre recharge).
    final bool seuilsOk = session.rechargerParametres();
    // Télécharge les référentiels avec la nouvelle configuration
    // ignore: unawaited_futures
    session.synchro.unePasseReferentiels(forcer: true);
    if (!mounted) return;
    setState(() => _erreur = null);
    session.push(
      seuilsOk
          ? 'Parametres enregistres - seuils et GPS appliques'
          : 'Parametres enregistres - seuils incoherents ignores, '
              'configuration precedente conservee',
    );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final MiseEnPage mise = MiseEnPage.depuis(context);
    final double k = mise.k;

    return Scaffold(
      backgroundColor: AppColors.paper,
      body: SafeArea(
        child: Column(
          children: [
            _Entete(k: k, titre: 'Parametres'),
            Expanded(
              child: SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(24 * k, 8 * k, 24 * k, 24 * k),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _Section(k: k, titre: 'Serveur (synchro)'),
                    _Champ(
                      k: k,
                      indice: 'api_base - racine de l\'API, sans slash final',
                      valeur: _apiBase,
                      clavier: TextInputType.url,
                    ),
                    _Champ(
                      k: k,
                      indice: 'api_token - jeton Bearer',
                      valeur: _apiToken,
                      masque: true,
                    ),
                    SizedBox(height: 10 * k),
                    // Test de sante (chaîne d'envoi vers le serveur central,
                    // point 5 du reste-a-faire) : un GET ?action=sante valide
                    // URL, jeton et deploiement Apps Script sans attendre la
                    // premiere passe de synchro.
                    SizedBox(
                      height: mise.hauteurBouton * 0.8,
                      child: Material(
                        color: AppColors.slate,
                        child: InkWell(
                          onTap: _testerServeur,
                          child: Center(
                            child: Text(
                              'Tester le serveur',
                              style: TextStyle(
                                fontSize: (17 * k).clamp(13.0, 17.0),
                                fontWeight: FontWeight.w700,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (_diagnosticServeur != null) ...[
                      SizedBox(height: 8 * k),
                      Text(
                        _diagnosticServeur!,
                        style: TextStyle(
                          fontSize: (13 * k).clamp(11.0, 13.0),
                          color: _diagnosticServeur!.startsWith('OK')
                              ? AppColors.green
                              : AppColors.red,
                        ),
                      ),
                    ],
                    SizedBox(height: 24 * k),
                    _Section(
                      k: k,
                      titre: 'Envoi des donnees du spotter',
                    ),
                    // RadioGroup porte la valeur du groupe (RadioListTile ne
                    // l'accepte plus depuis Flutter 3.35).
                    RadioGroup<String>(
                      groupValue: _envoiMode,
                      onChanged: (String? v) =>
                          setState(() => _envoiMode = v ?? _envoiMode),
                      child: Column(
                        children: [
                          for (final (code, libelle)
                              in const <(String, String)>[
                            (BaseLocale.envoiModeBlast,
                                'blast - tous les blocs verrouilles du blast'),
                            (BaseLocale.envoiModeBloc,
                                'bloc - le seul bloc courant'),
                            (BaseLocale.envoiModeVerrouilles,
                                'verrouilles - les seuls blocs verrouilles'),
                          ])
                            RadioListTile<String>(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              title: Text(
                                libelle,
                                style: TextStyle(
                                  fontFamily: kSerif,
                                  fontSize: (15 * k).clamp(12.0, 15.0),
                                  color: AppColors.ink,
                                ),
                              ),
                              value: code,
                              activeColor: AppColors.slate,
                            ),
                        ],
                      ),
                    ),
                    SizedBox(height: 16 * k),
                    _Section(
                      k: k,
                      titre: 'Detection d\'ecart hors-parcours',
                    ),
                    Row(
                      children: [
                        Expanded(
                          child: _Champ(
                            k: k,
                            indice: 'Entree (m)',
                            valeur: _seuilEntree,
                            clavier: TextInputType.number,
                          ),
                        ),
                        SizedBox(width: 12 * k),
                        Expanded(
                          child: _Champ(
                            k: k,
                            indice: 'Sortie (m)',
                            valeur: _seuilSortie,
                            clavier: TextInputType.number,
                          ),
                        ),
                        SizedBox(width: 12 * k),
                        Expanded(
                          child: _Champ(
                            k: k,
                            indice: 'Delai (s)',
                            valeur: _delai,
                            clavier: TextInputType.number,
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: 16 * k),
                    _Section(k: k, titre: 'GPS'),
                    Row(
                      children: [
                        Expanded(
                          child: _Champ(
                            k: k,
                            indice: 'Intervalle (s)',
                            valeur: _intervalle,
                            clavier: TextInputType.number,
                          ),
                        ),
                        SizedBox(width: 12 * k),
                        Expanded(
                          child: _Champ(
                            k: k,
                            indice: 'Filtre distance (m)',
                            valeur: _filtre,
                            clavier: TextInputType.number,
                          ),
                        ),
                      ],
                    ),
                    if (_erreur != null) ...[
                      SizedBox(height: 16 * k),
                      Text(
                        _erreur!,
                        style: TextStyle(
                          fontSize: (14 * k).clamp(11.0, 14.0),
                          color: AppColors.red,
                        ),
                      ),
                    ],
                    SizedBox(height: 24 * k),
                    SizedBox(
                      height: mise.hauteurBouton,
                      child: Material(
                        color: AppColors.slate,
                        child: InkWell(
                          onTap: _enregistrer,
                          child: Center(
                            child: Text(
                              'Enregistrer',
                              style: TextStyle(
                                fontSize: (20 * k).clamp(15.0, 20.0),
                                fontWeight: FontWeight.w700,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    SizedBox(height: 8 * k),
                    Text(
                      'api_base, api_token et envoi_mode sont relus a chaque '
                      'envoi : aucun redemarrage. Les seuils et le GPS '
                      's\'appliquent a l\'enregistrement.',
                      style: TextStyle(
                        fontSize: (12 * k).clamp(10.0, 12.0),
                        color: const Color(0xFF9A9DA1),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Bandeau de titre avec retour (meme famille que [AppHeader], en plus court).
class _Entete extends StatelessWidget {
  const _Entete({required this.k, required this.titre});

  final double k;
  final String titre;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.bar,
      height: (64 * k).clamp(48.0, 64.0),
      padding: EdgeInsets.symmetric(horizontal: 8 * k),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Retour',
            onPressed: () => Navigator.of(context).pop(),
            icon: Icon(Icons.arrow_back, color: Colors.white, size: 26 * k),
          ),
          SizedBox(width: 4 * k),
          Text(
            titre,
            style: TextStyle(
              fontFamily: kSerif,
              fontSize: (24 * k).clamp(18.0, 24.0),
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.k, required this.titre});

  final double k;
  final String titre;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(top: 8 * k, bottom: 6 * k),
      child: Text(
        titre,
        style: TextStyle(
          fontFamily: kSerif,
          fontSize: (17 * k).clamp(13.0, 17.0),
          fontWeight: FontWeight.w700,
          color: AppColors.slate,
        ),
      ),
    );
  }
}

/// Champ encadre de l'ecran Parametres, sur le meme dessin que les listes
/// deroulantes de la connexion (bordure 1.5 px, texte souligne serif).
class _Champ extends StatelessWidget {
  const _Champ({
    required this.k,
    required this.indice,
    required this.valeur,
    this.clavier,
    this.masque = false,
  });

  final double k;
  final String indice;
  final TextEditingController valeur;
  final TextInputType? clavier;
  final bool masque;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          indice,
          style: TextStyle(
            fontSize: (13 * k).clamp(11.0, 13.0),
            color: const Color(0xFF8A8D91),
          ),
        ),
        SizedBox(height: 4 * k),
        Container(
          decoration: BoxDecoration(
            border: Border.all(color: AppColors.border, width: 1.5),
          ),
          padding: EdgeInsets.symmetric(horizontal: 10 * k),
          child: TextField(
            controller: valeur,
            keyboardType: clavier,
            obscureText: masque,
            inputFormatters: clavier == TextInputType.number
                ? <TextInputFormatter>[
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                  ]
                : null,
            style: TextStyle(
              fontFamily: kSerif,
              fontSize: (16 * k).clamp(13.0, 16.0),
              color: AppColors.ink,
            ),
            decoration: const InputDecoration(
              border: InputBorder.none,
              isDense: true,
              contentPadding: EdgeInsets.symmetric(vertical: 10),
            ),
          ),
        ),
      ],
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

/// Espacements, tailles et options de mise en page calcules a partir de la
/// fenetre disponible.
///
/// L'echelle n'est plus calculee ici : elle vient de `flutter_screenutil`
/// (`ScreenUtilInit` pose dans `main.dart`, sur la taille de reference de la
/// maquette — tablette 14 pouces, 2240 x 1440 pixels, soit 1120 x 720 pixels
/// logiques a la densite 2,0).
///
/// Consequence directe : sur la tablette de reference, chaque valeur ci-dessous
/// reprend exactement le nombre ecrit dans la maquette, sans coefficient. Sur
/// une autre taille, `flutter_screenutil` applique la meme proportion a tout,
/// et `minTextAdapt` empeche le texte de devenir minuscule sur un telephone
/// comme geant sur un grand ecran.
///
/// Ce qui reste decide **ici** et non par la bibliotheque, parce que c'est un
/// choix de mise en page et pas une conversion de valeur :
/// - [aEmpile] : a partir de quelle largeur les deux colonnes s'empilent ;
/// - [margeEcran], [margePage] : les marges fixes du projet ;
/// - [ratioFilet] : la proportion du filet vertical.
///
/// Les widgets lisent [MiseEnPage] plutot que les extensions directement :
/// une seule classe decrit la mise en page, et changer une valeur ici la
/// change partout.
class MiseEnPage {
  const MiseEnPage({
    required this.aEmpile,
    required this.k,
    required this.margePage,
    required this.margeEcran,
    required this.hauteurLogo,
    required this.hauteurLogoSplash,
    required this.hauteurEntete,
    required this.hauteurTicker,
    required this.tailleBadge,
    required this.hauteurBandeau,
    required this.policeTitre,
    required this.ecartTitre,
    required this.ecartSection,
    required this.margeColonne,
    required this.ecartElement,
    required this.hauteurBouton,
    required this.largeurBouton,
    required this.margeFilet,
    required this.ratioFilet,
  });

  /// Coefficient d'echelle donne par `flutter_screenutil` (`.r`) : 1.0 sur la
  /// tablette de reference, moins sur un ecran plus petit, plus sur un plus
  /// grand.
  ///
  /// Il n'est plus utilise pour multiplier les tailles (les extensions le font
  /// deja) : il reste expose pour les ecarts sans dimension de reference, comme
  /// l'espace entre deux boutons d'un meme rang.
  final double k;

  /// Vrai quand les deux colonnes s'empilent (telephone, petite fenetre).
  ///
  /// Le seuil est en pixels **logiques** : la tablette de reference fait
  /// 1120 de large, donc elle ne s'empile jamais. Il faut descendre sous un
  /// telephone en paysage pour basculer — c'est exactement le comportement
  /// voulu (une tablette tournee ne doit pas changer de disposition).
  final bool aEmpile;

  final EdgeInsets margePage;

  /// Marge des trois ecrans profils (DT, excavator, spotter).
  ///
  /// Une seule valeur pour les trois : un ecran a l'autre, les blocs
  /// commencent exactement aux memes coordonnees.
  final EdgeInsets margeEcran;
  final double hauteurLogo;

  /// Logo du splash : nettement plus grand que celui de l'ecran de connexion,
  /// ou il joue le role de marque affichée seule.
  final double hauteurLogoSplash;

  /// Bandeau logo du haut des ecrans profils : 96 px en reference.
  final double hauteurEntete;

  /// Bandeau de notification du bas et les deux carres d'echange : 54 px en
  /// reference.
  final double hauteurTicker;

  /// Boite d'etat Wi-Fi / 4G : 180 x 140 en reference.
  final Size tailleBadge;

  final double hauteurBandeau;
  final double policeTitre;
  final double ecartTitre;
  final double ecartSection;
  final EdgeInsets margeColonne;
  /// Espacement entre deux elements d'une meme colonne.
  ///
  /// Une valeur unique est imposee volontairement : chaque colonne de l'ecran
  /// de connexion contient trois elements de hauteur identique (3 x
  /// hauteurBouton) separes par deux ecarts. Avec le meme espacement partout,
  /// les deux colonnes font exactement la meme hauteur, donc elles restent
  /// alignees en haut et en bas sans.spaceBetween, qui repartirait la
  /// hauteur restante entre les elements et les disperserait.
  final double ecartElement;
  final double hauteurBouton;
  final double largeurBouton;

  /// Espace de part et d'autre du filet vertical.
  final double margeFilet;

  /// Le filet vertical ne doit pas depasser cette fraction de la hauteur
  /// disponible : un trait pleine hauteur donne l'impression que les deux
  /// colonnes sont desavantagees.
  final double ratioFilet;

  factory MiseEnPage.depuis(BuildContext context) =>
      MiseEnPage.pour(MediaQuery.sizeOf(context));

  /// Vrai quand l'ecran est trop etroit ou trop bas pour le layout etale.
  ///
  /// Meme regle que celle employee dans `MiseEnPage.pour` pour choisir entre
  /// cote-a-cote et empile, exposee comme helper top-level pour qu'un widget
  /// puisse la consulter sans recreer une `MiseEnPage`.
  static bool estCompactPortrait(BuildContext context) {
    final Size taille = MediaQuery.sizeOf(context);
    return taille.width < 760 || taille.height < 720;
  }

  /// Construit la mise en page pour cette taille de fenetre.
  ///
  /// [taille] sert au seul choix qui ne depend pas de l'echelle : empiler ou
  /// non les colonnes. Toutes les dimensions passent par les extensions de
  /// `flutter_screenutil`, qui lisent la taille reelle de l'ecran — donc la
  /// rotation et le redimensionnement sont pris en compte sans code
  /// supplementaire.
  factory MiseEnPage.pour(Size taille) {
    // Seuil d'empilement des deux colonnes, en pixels logiques.
    //
    // Deux conditions equivalentes :
    //   1. la fenetre est etroite (< 760 de large) — telephone en paysage
    //      ou petite fenetre partagee ;
    //   2. la fenetre est plus haute que large — tablette tournee en portrait
    //      ou telephone en portrait.
    //
    // La condition 2 evite le rendu degrade observe a 768x1024 (iPad portrait)
    // ou le mode cote-a-cote coupait les colonnes en plein milieu d'un trait
    // vertical mal positionne. Un iPad en paysage (> 760 de large et plus large
    // que haut) garde le cote-a-cote, comme prevu par la maquette.
    final bool empile = taille.width < 760 || taille.height > taille.width;

    return MiseEnPage(
      // `.r` : la plus petite des deux proportions (largeur, hauteur), donc
      // l'echelle qui ne fait jamais deborder.
      k: 1.0.r,
      aEmpile: empile,
      // Marges de page : proportionnelles a la hauteur, pour que le bloc
      // logo + titre garde sa respiration verticale d'un ecran a l'autre.
      margePage: EdgeInsets.fromLTRB(50.r, 40.r, 50.r, 8.r),
      // Marge des ecrans profils : c'est un encadrement, donc le petit cote
      // (`.r`) — elle ne doit pas s'aplatir sur un ecran large et bas.
      margeEcran: EdgeInsets.all(18.r),
      hauteurLogo: 140.r,
      hauteurLogoSplash: 350.r,
      hauteurEntete: 96.r,
      hauteurTicker: 54.r,
      // Badge nettement plus compact que la maquette historique (150x130).
      // L'ecran DT en affiche plusieurs en ligne ; une taille proportionnelle
      // au petit cote evite qu'ils prennent la largeur sur telephone/tablette.
      tailleBadge: Size((78 * 1.0.r).clamp(58.0, 88.0), (66 * 1.0.r).clamp(50.0, 72.0)),
      hauteurBandeau: 64.r,
      policeTitre: 34.sp,
      // Espacements : le petit cote (`.r`). En `.h` ils ne depassent pas sur la
      // reference, mais un ecran large et bas (telephone en paysage, rapport
      // 2,2 contre 1,55 pour la tablette) les gardait trop grands et faisait
      // deborder la colonne.
      ecartTitre: 12.r,
      ecartSection: 50.r,
      // Marge verticale seulement : l'espace horizontal autour du trait est
      // gere par `margeFilet`, sinon les deux marges se cumulent et le trait
      // reste tres eloigne des boutons et des champs.
      margeColonne: EdgeInsets.symmetric(vertical: 6.r),
      ecartElement: 10.r,
      hauteurBouton: 50.r,
      largeurBouton: 250.r,
      margeFilet: 17.r,
      ratioFilet: 1.2,
    );
  }
}

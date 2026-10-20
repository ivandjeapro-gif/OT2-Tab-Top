import 'dart:typed_data';

/// Un profil de la table `profils` (CDC §2.3, REQ-002).
///
/// Le CDC ne parle que du **rôle** : `ROLE_TAB1`, `ROLE_TAB2` ou `ROLE_TAB3`,
/// enregistré localement à l'enrôlement. C'est [roleCdc] qui range l'appareil
/// dans la table `equipements` et qui décide de la passerelle BLE/Wi-Fi.
///
/// Le profil est le même rôle vu par l'interface : son libellé de bouton, son
/// titre d'écran et son rang de présentation. Rien n'est écrit ici en dur —
/// la liste vient de `base.profils()` et peut donc être corrigée sans
/// redéployer l'application.
class Profil {
  const Profil({
    required this.code,
    required this.libelle,
    required this.titre,
    required this.roleCdc,
    required this.icone,
    required this.ordre,
    this.actif = true,
  });

  /// Code interne, cle primaire de la table : `dt`, `excavator`, `spotter`.
  final String code;

  /// Texte du bouton de sélection (« Driving Truck - DT »).
  final String libelle;

  /// Titre affiché par l'écran du profil.
  final String titre;

  /// Rôle porté par l'équipement (CDC §2.3, REQ-002) : `ROLE_TAB1` à `TAB3`.
  ///
  /// Une seule application, trois rôles. Les identifiants et les noms
  /// proposés au login ne viennent pas d'ici : ils sont lus dans
  /// `equipements` (`BaseLocale.idsDuProfil`, `BaseLocale.nomsDuProfil`).
  final String roleCdc;

  /// Code d'icône Material, réservé à l'affichage.
  final String icone;

  /// Rang de présentation dans le sélecteur.
  final int ordre;

  /// Vrai si le profil est proposé à la connexion.
  final bool actif;

  @override
  bool operator ==(Object other) => other is Profil && other.code == code;

  @override
  int get hashCode => code.hashCode;

  @override
  String toString() => 'Profil($code)';
}

/// Une ligne de donnees saisie par le spotter.
///
/// Le blast, le bloc et la carte ne sont volontairement pas stockes ici : une
/// ligne appartient toujours a un seul bloc (une seule carte), donc ces
/// informations se deduisent de l'arbre Blast > BlocTravail. Les dupliquer
/// obligerait a les resynchroniser a chaque ajout, avec le risque qu'une ligne
/// se retrouve rattachee au mauvais bloc.
class LigneBlast {
  const LigneBlast({
    required this.time,
    required this.dt,
    required this.idDt,
    this.hasPicture = false,
    this.photo,
    this.comment = '',
  });

  final String time;

  /// Type du DT choisi dans la premiere liste (1500, 785, 2000).
  final String dt;

  /// Numero du DT, choisi dans le lot du type. Depend de [dt] : un numero
  /// n'existe que dans le lot de son type.
  final String idDt;

  final bool hasPicture;

  /// Octets de la photo reellement capturee sur l'appareil. Null quand la
  /// ligne n'a pas de photo (ou qu'elle vient d'un seed qui ne porte que le
  /// drapeau [hasPicture]).
  final Uint8List? photo;

  final String comment;
}

/// Une categorie de DT, avec le lot de DT qui la compose.
///
/// Le type est le chapeau de la premiere liste deroulante, et ses [ids] sont
/// ce que propose la seconde : les deux listes sont liees, choisir un type
/// change le contenu du lot.
///
/// Les identifiants sont non redondants sur tout le parc : le DT 01 n'existe
/// que dans la famille 1500, il ne peut donc pas apparaitre dans une autre
/// famille.
class TypeDT {
  const TypeDT({required this.code, required this.ids});

  final String code;
  final List<String> ids;

  int get nombreDts => ids.length;

  /// Nom affiche par la liste deroulante.
  ///
  /// L'onglet `dts` porte des familles deja nommees (`1500`, `785`, `ADT`) :
  /// on prefixe `DT` pour les familles numeriques (« DT 1500 ») et on laisse
  /// `ADT` tel quel, sans produire « DT ADT ». Un code vide rend « DT ».
  String get libelle =>
      code.isEmpty ? 'DT' : (code.startsWith('ADT') ? code : 'DT $code');

  /// Vrai si ce numero appartient bien a ce type de DT.
  bool contient(String id) => ids.contains(id);
}

/// Un bloc de travail : appartient a un seul blast.
///
/// Toutes les lignes saisies dans le tableau du spotter appartiennent au bloc
/// selectionne, jamais a un autre.
///
/// Un bloc porte sa propre carte : un blast peut couvrir plusieurs cartes
/// (une par RL = Relative Level = 1er segment du code carte), et chaque bloc
/// appartient a l'une d'elles. Cela permet le filtrage par RL cote UI.
class BlocTravail {
  BlocTravail({
    required this.numero,
    required this.carte,
    List<LigneBlast>? lignes,
    this.verrouille = false,
  }) : lignes = lignes ?? <LigneBlast>[];

  final String numero;

  /// Code de la carte sur laquelle travaille ce bloc.
  ///
  /// Le RL est derive de cette carte via `decoderCarte(carte)?.flitch` :
  /// on evite une colonne redondante pour limiter les risques d'incoherence.
  final String carte;

  final List<LigneBlast> lignes;

  /// Vrai quand ce bloc (et lui seul) est verrouille.
  ///
  /// Le verrou porte sur la **paire (blast, bloc)** et non sur le blast
  /// entier : verrouiller le bloc 8 laisse le bloc 6 du meme blast
  /// libre de recevoir des lignes, jusqu'a ce qu'on change de selection
  /// (la paire change donc le verrou « saute »).
  bool verrouille;

  int get nombreLignes => lignes.length;
}

/// Un blast : couvre plusieurs cartes (une par RL), chacune avec ses blocs.
///
/// Architecture de selection : Blast -> RL -> Bloc. Le RL est le premier
/// segment du code carte (flitch). La nomenclature cote serveur etendue est :
/// `flitch_activite_site_profDebut_profFin_pattern[_nbBlocs]`.
class Blast {
  Blast({
    required this.numero,
    required this.blocs,
    required this.cartes,
    required this.plan,
    this.envoye = false,
  });

  /// Constructeur retrocompatible : un seul `carte` (ancien format) est
  /// enveloppe dans une liste d'une carte. Les blasts envoyes par un serveur
  /// non encore migre vers le nouveau format continuent de fonctionner.
  Blast.legacy({
    required String numero,
    required List<BlocTravail> blocs,
    required String carte,
    required String plan,
    bool envoye = false,
  }) : this(
          numero: numero,
          blocs: blocs,
          cartes: <String>[carte],
          plan: plan,
          envoye: envoye,
        );

  final String numero;
  final List<BlocTravail> blocs;

  /// Codes des cartes couvertes par ce blast (une par RL).
  ///
  /// Mutable : la reception serveur peut requalifier la liste des cartes d'un
  /// blast deja connu (jusqu'ici l'ecriture locale n'y touche jamais).
  List<String> cartes;

  /// Fichier JPG du plan : le blast ne detient que celui de la carte
  /// selectionnee via le RL courant. Vide tant qu'aucun RL n'est choisi.
  ///
  /// Mutable pour la meme raison : le worker y pose le chemin du fichier
  /// local une fois le plan telecharge du serveur.
  String plan;

  /// Vrai quand **tous** les blocs de ce blast sont verrouilles.
  ///
  /// Le verrou lui-meme vit sur chaque bloc (paire blast/bloc) : ce getter
  /// ne fait que dire si le blast est integralement ferme, ce que lit le
  /// mode d'envoi `blast` et les affichages « - verrouille ».
  bool get verrouille => blocs.isNotEmpty && blocs.every((b) => b.verrouille);

  /// Compatibilite ascendante : renvoie la premiere carte du blast, ou `''`.
  ///
  /// A eviter dans le nouveau code : preferer [cartes] et [carteDuRl].
  String get carte => cartes.isNotEmpty ? cartes.first : '';

  /// Vrai quand les donnees de ce blast ont ete transmises au point d'acces.
  ///
  /// Perd ce statut des que l'un de ses blocs est rouvert : les donnees
  /// deviennent de nouveau modifiables, donc elles ne sont plus a jour.
  bool envoye;

  /// Nombre de blocs du blast, affiche dans la selection.
  int get nombreBlocs => blocs.length;

  /// Nombre de cartes (RL) couvertes par le blast.
  int get nombreCartes => cartes.length;

  /// RL distincts des cartes du blast, dans l'ordre de la liste [cartes].
  ///
  /// Vide si aucune carte n'est exploitable (nomenclature invalide).
  /// Un meme RL peut theoriquement apparaitre plusieurs fois si le serveur
  /// envoyait deux cartes au meme flitch, mais on de-duplique en conservant
  /// l'ordre.
  List<String> get rls {
    final List<String> v = <String>[];
    for (final String code in cartes) {
      final String? rl = decoderCarte(code)?.flitch;
      if (rl == null || rl.isEmpty) continue;
      if (!v.contains(rl)) v.add(rl);
    }
    return v;
  }

  /// Carte correspondant au RL donne, ou null si aucune carte ne matche.
  String? carteDuRl(String rl) {
    for (final String code in cartes) {
      if (decoderCarte(code)?.flitch == rl) return code;
    }
    return null;
  }

  /// Blocs dont la carte appartient au RL donne.
  List<BlocTravail> blocsDuRl(String rl) => blocs
      .where((BlocTravail b) => decoderCarte(b.carte)?.flitch == rl)
      .toList(growable: false);

  /// Blocs regroupes par RL (flitch), dans l'ordre des cartes du blast.
  ///
  /// C'est la vue de reference de l'ecran spotter : chaque RL porte
  /// uniquement ses propres blocs, meme lorsque deux RL d'un meme blast
  /// numérotent leurs blocs de 1 a n (ils ne se melangent donc jamais).
  Map<String, List<BlocTravail>> get blocsParRl {
    final Map<String, List<BlocTravail>> sortie =
        <String, List<BlocTravail>>{};
    for (final String rl in rls) {
      sortie[rl] = blocsDuRl(rl);
    }
    return sortie;
  }

  /// Bloc identifie par sa paire (numero, carte).
  ///
  /// Quand [carte] est fournie, la recherche est STRICTE : un bloc de meme
  /// numero appartenant a un autre RL n'est jamais retourne. Deux RL d'un
  /// meme blast numerotent leurs blocs de 1 a n ; confondre les deux ferait
  /// afficher les blocs de 260 sur le RL 262.5.
  BlocTravail? bloc(String numero, {String? carte}) {
    if (carte != null && carte.isNotEmpty) {
      for (final b in blocs) {
        if (b.numero == numero && b.carte == carte) return b;
      }
      return null;
    }
    for (final b in blocs) {
      if (b.numero == numero) return b;
    }
    return null;
  }

  /// Vrai si ce blast contient deja le bloc [numero] sur la [carte] donnee.
  bool aBloc(String numero, String carte) {
    for (final b in blocs) {
      if (b.numero == numero && b.carte == carte) return true;
    }
    return false;
  }

  /// Nombre de lignes du blast entier, tous blocs confondus.
  int get nombreLignes =>
      blocs.fold<int>(0, (total, bloc) => total + bloc.nombreLignes);
}

/// Resultat du decodage d'un code de carte selon la nomenclature du site.
///
/// Le 7ᵉ segment (`nbBlocs`) est **optionnel** : il vaut `null` sur les anciens
/// codes a 6 segments (le caller retombe alors sur l'onglet `blocs` du serveur).
class CarteDecodee {
  const CarteDecodee({
    required this.flitch,
    required this.activite,
    required this.site,
    required this.profDebut,
    required this.profFin,
    required this.pattern,
    this.nbBlocs,
  });

  final String flitch;
  final String activite;
  final String site;
  final String profDebut;
  final String profFin;
  final String pattern;

  /// Nombre de blocs/polygones portes par le nom (7ᵉ segment), ou `null`
  /// si le code utilise l'ancien format a 6 segments.
  final int? nbBlocs;
}

/// Decode un code de carte selon la nomenclature :
///   `flitch_activite_site_profDebut_profFin_pattern[_nbBlocs]`
///
/// Retourne `null` si le code ne respecte pas la nomenclature (mauvais nombre
/// de segments, profondeur non numerique, `nbBlocs` non entier strictement
/// positif). Le caller decide alors quoi faire (rejet silencieux, journal,
/// alerte UI).
///
/// Cote serveur (`server_OT` / `decoderCarte`) applique la meme regle ; cette
/// version Dart sert aux validations et affichages locaux (par exemple comparer
/// `nbBlocs` avec le nombre de blocs recus du serveur, ou deriver le RL d'un
/// bloc depuis sa carte).
CarteDecodee? decoderCarte(String? code) {
  final String s = (code ?? '').trim();
  if (s.isEmpty) return null;
  final List<String> seg = s.split('_');
  if (seg.length != 6 && seg.length != 7) return null;
  if (seg[0].isEmpty || seg[1].isEmpty || seg[2].isEmpty || seg[5].isEmpty) {
    return null;
  }
  final RegExp profondeur = RegExp(r'^[0-9.]+$');
  if (!profondeur.hasMatch(seg[3]) || !profondeur.hasMatch(seg[4])) return null;
  int? nbBlocs;
  if (seg.length == 7) {
    final RegExp entier = RegExp(r'^[0-9]+$');
    if (!entier.hasMatch(seg[6])) return null;
    final int? n = int.tryParse(seg[6]);
    if (n == null || n < 1) return null;
    nbBlocs = n;
  }
  return CarteDecodee(
    flitch: seg[0],
    activite: seg[1],
    site: seg[2],
    profDebut: seg[3],
    profFin: seg[4],
    pattern: seg[5],
    nbBlocs: nbBlocs,
  );
}

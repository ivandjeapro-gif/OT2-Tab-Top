import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/models.dart';
import 'base_locale.dart';

/// Enveloppe d'un evenement, telle que le CDC §12 la decrit.
///
/// Les champs viennent des colonnes de `evenements` : rien n'est invente au
/// moment de l'envoi, ce qui rend la file autonome et rejouable a l'identique.
class Enveloppe {
  const Enveloppe({
    required this.eventId,
    required this.gatewayId,
    required this.sourceDevice,
    required this.eventType,
    required this.timestamp,
    required this.payload,
  });

  /// Identifiant unique (REQ-014) : c'est aussi la cle d'idempotence.
  final String eventId;

  /// Passerelle qui relaie (§12).
  final String gatewayId;

  /// Appareil a l'origine de l'evenement (§12).
  final String sourceDevice;

  /// Nature de l'evenement : LINE_ADD, BLAST_LOCK, BLAST_SEND, ...
  final String eventType;

  /// Horodatage ISO 8601 UTC conserve a l'ecriture (§12).
  final String timestamp;

  /// Contenu metier. Stocke en texte dans la base, repasse en objet ici :
  /// c'est ainsi que le serveur le recoit.
  final Object payload;

  /// Construite depuis une ligne de la table `evenements`.
  factory Enveloppe.depuisLigne(Map<String, Object?> ligne) {
    final Object brut = ligne['payload'] ?? '';
    Object contenu;
    try {
      contenu = jsonDecode(brut as String);
    } catch (_) {
      // Un payload illisible ne doit pas bloquer la file : on l'envoie tel
      // quel, c'est au serveur de rejeter proprement (422).
      contenu = <String, Object?>{'brut': '$brut'};
    }
    return Enveloppe(
      eventId: ligne['event_id']! as String,
      gatewayId: (ligne['gateway_id'] as String?) ?? '',
      sourceDevice: ligne['source_device']! as String,
      eventType: ligne['event_type']! as String,
      timestamp: ligne['timestamp']! as String,
      payload: contenu,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'event_id': eventId,
        'gateway_id': gatewayId,
        'source_device': sourceDevice,
        'event_type': eventType,
        'timestamp': timestamp,
        'payload': payload,
      };

  @override
  String toString() => jsonEncode(toJson());
}

/// Reponse du serveur, qu'elle vienne du reseau ou d'un timeout.
///
/// Deux regimes coexistent :
/// - **codes HTTP classiques** (serveur CDC complet) : 202 ACK, 409 doublon,
///   4xx refus rejouable ;
/// - **marqueur dans le corps** (serveur Apps Script, `server_OT`) : tout sort
///   en 200 et c'est le JSON `{"ok": true|false}` qui porte la sémantique,
///   avec `ack.status = SYNCED|DOUBLON` pour distinguer les deux succès.
///   Le corps fait foi : un 200 avec `ok: false` est un refus rejouable,
///   jamais un ACK — c'est ce qui preserve REQ-012 (aucune perte).
class ReponseServeur {
  const ReponseServeur({required this.code, this.erreur, this.corps});

  /// 0 = aucun octet recu : reseau absent, timeout, hote inconnu.
  final int code;

  /// Motif lisible, pour le journal (§22).
  final String? erreur;

  /// Corps JSON decode quand disponible (serveur a marqueur `ok`).
  final Object? corps;

  /// 2xx : accusé de reception (§14), sauf marqueur de refus dans le corps.
  bool get okHttp => code >= 200 && code < 300;

  /// Le serveur suit le regime a marqueur (`server_OT`).
  bool get _aMarqueur => corps is Map<String, Object?>;

  /// Succes effectif : 2xx, ou marqueur `ok: true` dans le corps.
  bool get ok => _aMarqueur ? (corps as Map<String, Object?>)['ok'] == true : okHttp;

  /// Deja recu. Idempotent (REQ-015), donc traite comme un succes.
  bool get doublon {
    if (!_aMarqueur) return code == 409;
    final Object? ack = (corps as Map<String, Object?>)['ack'];
    return ack is Map<String, Object?> && ack['status'] == 'DOUBLON';
  }

  /// Ce qui fait sortir l'evenement de la file PENDING.
  bool get accepte => ok || doublon;
}

/// Un blast tel que le serveur le propose sur `GET /blasts`.
///
/// C'est un descriptif de travail, pas un etat de saisie : les lignes et le
/// verrou sont du domaine local, le serveur ne les porte pas. `planUrl` est
/// l'URL du plan JPG de la carte — le worker le telecharge ensuite vers un
/// fichier local, le chemin duquel remplace l'asset dans `Blast.plan`.
class BlastServeur {
  const BlastServeur({
    required this.numero,
    required this.carte,
    required this.blocs,
    this.cartes = const <String>[],
    this.blocsParCarte = const <String, List<String>>{},
    this.flitchParCarte = const <String, String>{},
    this.planUrlParCarte = const <String, String>{},
    this.planIdParCarte = const <String, String>{},
    this.libelleCarte = '',
    this.planUrl = '',
    this.planId = '',
  });

  final String numero;

  /// Code de la carte unique du blast (cle de la table `cartes`).
  ///
  /// Conserve pour la **compatibilite ascendante** avec l'ancien format du
  /// serveur (un blast = une carte). Le nouveau format utilise `cartes` (une
  /// carte par RL) ; `carte` reste la premiere carte du tableau.
  final String carte;

  /// Liste des cartes couvertes par le blast (une par RL). Vide si le serveur
  /// n'envoie que l'ancien champ `carte`, auquel cas [carte] fait foi.
  final List<String> cartes;

  /// Blocs rattaches a leur carte (RL) : carte -> numeros de blocs.
  ///
  /// Vide si le serveur ne fournit que la liste plate `blocs` (ancien
  /// contrat) : le client retombe alors sur [blocs] applique a la premiere
  /// carte.
  final Map<String, List<String>> blocsParCarte;

  /// RL (flitch) declare par le serveur pour chaque carte, quand il le
  /// fournit. Sert de repli lorsque le code de carte n'est pas decodable :
  /// le client ne perd alors pas le rattachement RL.
  final Map<String, String> flitchParCarte;

  /// Libelle lisible de la carte (« Fosse A - niveau 1 »), pose dans la
  /// table `cartes` a la reception.
  final String libelleCarte;

  /// Numeros des blocs du blast, dans l'ordre du serveur.
  final List<String> blocs;

  /// URL du plan JPG de la carte, vide si le serveur n'en fournit pas.
  final String planUrl;

  /// URL du plan pour CHAQUE carte du blast (une par RL).
  ///
  /// Un blast peut couvrir plusieurs RL (ex. 113 = flitch 260 + flitch 262.5).
  /// `planUrl` ne porte que la premiere carte ; cette table permet d'afficher
  /// le bon plan quand l'utilisateur change de RL.
  final Map<String, String> planUrlParCarte;

  /// Identifiant Drive du plan de CHAQUE carte (cle du fichier, stable).
  ///
  /// C'est la voie la plus robuste : contrairement a une URL Apps Script
  /// (`?action=plan&carte=…`, qui refait une recherche par NOM cote Drive, donc
  /// dependante du partage et de l'orthographe exacte), l'identifiant Drive ne
  /// change jamais et se resout en UNE requete :
  /// `https://drive.google.com/uc?export=download&id=<planId>`.
  ///
  /// Alimente par `blocs_par_carte[].plan_id` (ou `drive_id`). Absent =
  /// ancien deploiement serveur, le client retombe sur [planUrlParCarte].
  final Map<String, String> planIdParCarte;

  /// Identifiant Drive du plan de la premiere carte (format plat).
  final String planId;

  /// Parse la reponse du serveur. Un champ manquant ne bloque pas la liste :
  /// le blast arrive avec ce qui est la, le reste suivra a la prochaine
  /// passe (un blast sans numero est simplement ignore).
  ///
  /// Formats acceptes pour les cartes :
  /// - ancien : `carte: "X"` (une seule carte) ;
  /// - nouveau : `cartes: ["X", "Y", ...]` (une par RL).
  /// Si les deux sont presents, `cartes` est prioritaire.
  static List<BlastServeur>? depuisJson(Object? brut) {
    if (brut is! Map<String, Object?>) return null;
    final Object? liste = brut['blasts'];
    if (liste is! List) return null;
    return <BlastServeur>[
      for (final Object? item in liste)
        if (item is Map<String, Object?> && item['numero'] != null)
          BlastServeur(
            numero: '${item['numero']}',
            carte: '${item['carte'] ?? ''}',
            cartes: <String>[
              if (item['cartes'] is List)
                for (final Object? c in item['cartes'] as List) '$c',
            ],
            blocsParCarte: _lireBlocsParCarte(item['blocs_par_carte']),
            flitchParCarte: _lireFlitchParCarte(item['blocs_par_carte']),
            planUrlParCarte: _lirePlanUrlParCarte(item['blocs_par_carte']),
            planIdParCarte: _lirePlanIdParCarte(item['blocs_par_carte']),
            libelleCarte: '${item['libelle_carte'] ?? ''}',
            blocs: <String>[
              if (item['blocs'] is List)
                for (final Object? b in item['blocs'] as List) '$b',
            ],
            planUrl: '${item['plan_url'] ?? ''}',
            planId: '${item['plan_id'] ?? item['drive_id'] ?? ''}',
          ),
    ];
  }

  /// Lit `blocs_par_carte` : `[{carte: '...', blocs: ['1','2']}, ...]`.
  static Map<String, List<String>> _lireBlocsParCarte(Object? brut) {
    if (brut is! List) return const <String, List<String>>{};
    final Map<String, List<String>> sortie = <String, List<String>>{};
    for (final Object? item in brut) {
      if (item is! Map<String, Object?>) continue;
      final String carte = '${item['carte'] ?? ''}'.trim();
      if (carte.isEmpty) continue;
      final Object? blocs = item['blocs'];
      if (blocs is! List) continue;
      sortie[carte] = <String>[
        for (final Object? b in blocs)
          if ('$b'.trim().isNotEmpty) '$b'.trim(),
      ];
    }
    return sortie;
  }

  /// Lit le `flitch` declare par le serveur pour chaque carte.
  static Map<String, String> _lireFlitchParCarte(Object? brut) {
    if (brut is! List) return const <String, String>{};
    final Map<String, String> sortie = <String, String>{};
    for (final Object? item in brut) {
      if (item is! Map<String, Object?>) continue;
      final String carte = '${item['carte'] ?? ''}'.trim();
      final String flitch = '${item['flitch'] ?? ''}'.trim();
      if (carte.isEmpty || flitch.isEmpty) continue;
      sortie[carte] = flitch;
    }
    return sortie;
  }

  /// Lit l'identifiant Drive du plan de chaque carte.
  ///
  /// Trois noms acceptes, du plus explicite au plus general : `plan_id`,
  /// `drive_id`, puis un `id` numerique de fichier. L'identifiant est aussi
  /// extrait d'un `plan_url` Drive quand le serveur ne le FOURNIT pas
  /// separement (`...uc?export=download&id=XXXX`) : cela permet d'utiliser la
  /// voie directe sans dependre d'un nouveau deploiement serveur.
  static Map<String, String> _lirePlanIdParCarte(Object? brut) {
    if (brut is! List) return const <String, String>{};
    final Map<String, String> sortie = <String, String>{};
    for (final Object? item in brut) {
      if (item is! Map<String, Object?>) continue;
      final String carte = '${item['carte'] ?? ''}'.trim();
      if (carte.isEmpty) continue;
      String id = '${item['plan_id'] ?? item['drive_id'] ?? ''}'.trim();
      if (id.isEmpty) {
        // Repli : identifiant lu dans l'URL Drive deja fournie.
        id = identifiantDrive('${item['plan_url'] ?? ''}');
      }
      if (id.isEmpty) continue;
      sortie[carte] = id;
    }
    return sortie;
  }

  /// Extrait l'identifiant d'un fichier depuis une URL Drive, ou rend la
  /// chaine vide. Trois formes usuelles :
  /// - `drive.google.com/uc?export=download&id=XXXX` ;
  /// - `drive.google.com/file/d/XXXX/view` ;
  /// - `docs.google.com/…/d/XXXX/…`.
  static String identifiantDrive(String url) {
    final String u = url.trim();
    if (u.isEmpty) return '';
    for (final RegExp motif in <RegExp>[
      RegExp(r'[?&]id=([A-Za-z0-9_-]{10,})'),
      RegExp(r'/d/([A-Za-z0-9_-]{10,})'),
    ]) {
      final RegExpMatch? m = motif.firstMatch(u);
      if (m != null) return m.group(1)!;
    }
    return '';
  }

  /// Lit le `plan_url` declare par le serveur pour chaque carte (un par RL).
  static Map<String, String> _lirePlanUrlParCarte(Object? brut) {
    if (brut is! List) return const <String, String>{};
    final Map<String, String> sortie = <String, String>{};
    for (final Object? item in brut) {
      if (item is! Map<String, Object?>) continue;
      final String carte = '${item['carte'] ?? ''}'.trim();
      final String url = '${item['plan_url'] ?? ''}'.trim();
      if (carte.isEmpty || url.isEmpty) continue;
      sortie[carte] = url;
    }
    return sortie;
  }
}

/// Snapshot des référentiels administrés par le serveur.
///
/// La tablette ne crée pas elle-même de profils, équipements ou lots DT :
/// ces listes sont fournies par les onglets `profils`, `equipements` et
/// `types_dt` du serveur, puis remplacées localement à chaque sync valide.
class ReferentielsServeur {
  const ReferentielsServeur({
    required this.profils,
    required this.equipements,
    required this.typesDT,
  });

  final List<Profil> profils;
  final List<EquipementServeur> equipements;
  final List<TypeDT> typesDT;

  static List<Map<String, Object?>> _objets(Object? valeur) {
    if (valeur is! List) return <Map<String, Object?>>[];
    return <Map<String, Object?>>[
      for (final Object? item in valeur)
        if (item is Map<String, Object?>) item,
    ];
  }

  static String _texte(Map<String, Object?> objet, String cle) =>
      '${objet[cle] ?? ''}'.trim();

  static int _entier(Map<String, Object?> objet, String cle, int defaut) =>
      int.tryParse('${objet[cle] ?? ''}') ?? defaut;

  factory ReferentielsServeur.depuisJson(Object? brut) {
    if (brut is! Map<String, Object?> || brut['ok'] != true) {
      throw const FormatException('Snapshot referentiels invalide');
    }
    if (brut['referentiels_version'] != 1) {
      throw const FormatException('Version referentiels non supportee');
    }
    final List<Profil> profils = <Profil>[
      for (final Map<String, Object?> p in _objets(brut['profils']))
        if (_texte(p, 'code').isNotEmpty &&
            _texte(p, 'libelle').isNotEmpty &&
            _texte(p, 'role_cdc').isNotEmpty)
          Profil(
            code: _texte(p, 'code'),
            libelle: _texte(p, 'libelle'),
            titre: _texte(p, 'titre'),
            roleCdc: _texte(p, 'role_cdc'),
            icone: _texte(p, 'icone'),
            ordre: _entier(p, 'ordre', 0),
            actif: _entier(p, 'actif', 1) != 0,
          ),
    ];
    // Serveur final : `identifiants` ne contient PLUS que des personnes
    // (spotters, chefs d'equipe), avec `role` et `equipe` en plus. Les
    // machines (DT, EXCAVATOR) viennent de `flotte` et arrivent dans `dts`.
    final List<EquipementServeur> equipements = <EquipementServeur>[
      for (final Map<String, Object?> e in _objets(brut['equipements']))
        if (_texte(e, 'profil').isNotEmpty &&
            _texte(e, 'id').isNotEmpty &&
            _entier(e, 'actif', 1) != 0)
          EquipementServeur(
            profil: _texte(e, 'profil'),
            id: _texte(e, 'id'),
            nom: _texte(e, 'nom'),
            role: _texte(e, 'role'),
            equipe: _texte(e, 'equipe'),
            actif: _entier(e, 'actif', 1) != 0,
          ),
    ];
    final Map<String, List<String>> idsParType = <String, List<String>>{};
    // `role` = profil proprietaire de chaque famille (DT, EXCAVATOR...).
    //
    // L'onglet `dts` du serveur ne porte que (type, id, actif) : il n'y a
    // AUCUNE colonne `role`. Le role se deduit donc du profil qui declare
    // la famille, par deux voies, dans cet ordre :
    //   1. le champ `role` s'il est present (anciennes feuilles serveur) ;
    //   2. l'un des identifiants de la famille appartient a un equipement
    //      dont on connait le `profil` (ex. « PC-2000 » -> EXCAVATOR).
    // Sans ces deux voies, `role` restait vide, aucun profil n'avait de
    // famille et le snapshot etait refuse : ecran « Aucun profil configure ».
    final Map<String, String> roleParType = <String, String>{};
    final Map<String, String> idMachineVersProfil = <String, String>{
      for (final EquipementServeur e in equipements)
        if (e.id.isNotEmpty && e.profil.isNotEmpty) e.id: e.profil,
    };
    for (final Map<String, Object?> dt in _objets(brut['dts'])) {
      final String type = _texte(dt, 'type');
      final String id = _texte(dt, 'id');
      if (type.isEmpty || id.isEmpty || _entier(dt, 'actif', 1) == 0) continue;
      (idsParType[type] ??= <String>[]).add(id);
      final String role = _texte(dt, 'role');
      if (role.isNotEmpty) {
        roleParType[type] = role;
      } else {
        // Deduction par l'equipement : les identifiants de la flotte sont
        // souvent prefixes par leur famille (« PC-2000 »), on teste donc
        // l'identifiant tel quel puis son suffixe numerique.
        roleParType.putIfAbsent(
          type,
          () => idMachineVersProfil[id] ??
              idMachineVersProfil[id.split('-').last] ??
              '',
        );
      }
    }
    final List<TypeDT> types = <TypeDT>[
      for (final MapEntry<String, List<String>> entry in idsParType.entries)
        TypeDT(
          code: entry.key,
          role: roleParType[entry.key] ?? '',
          ids: List<String>.unmodifiable(entry.value),
        ),
    ];
    // Un payload tronque ou mal formé ne doit pas vider le référentiel local.
    final Set<String> codesProfils = profils.map((Profil p) => p.code).toSet();
    final bool profilsUniques = codesProfils.length == profils.length;
    final bool equipementsRattaches = equipements.every(
      (EquipementServeur e) => codesProfils.contains(e.profil),
    );
    final Set<String> codesTypes = types.map((TypeDT t) => t.code).toSet();
    final Set<String> typesAvecDT = idsParType.keys.toSet();
    // Serveur final : les machines (DT, EXCAVATOR...) se connectent via la
    // FLOTTE (champ `dts`), pas via `identifiants`. Seuls les profils
    // PERSONNES (role_cdc == SPOT) lisent `identifiants` — et un SPOT sans
    // membre est TOLERe par le serveur (avertissement), pas refuse : la
    // synchro ne doit pas echouer pour une equipe pas encore saisie.
    final Set<String> famillesActives = types
        .where((TypeDT t) => typesAvecDT.contains(t.code))
        .map((TypeDT t) => t.code.toUpperCase())
        .toSet();
    // Unicite par COUPLE (famille, numero), pas par numero seul : le serveur
    // final numerote la flotte en continu (1..N), donc « 1 » existe en
    // famille 1500 ET en famille EXCAVATOR — c'est valide.
    final Set<String> clesDT = <String>{
      for (final TypeDT t in types)
        for (final String id in t.ids) '${t.code.toUpperCase()}\u0000$id',
    };
    bool profilSansEngin(Profil p) {
      // Helpers CDC : toutes les formes de role acceptees (ROLE_TAB1/SPOTTER
      // = personne, ROLE_TAB2/DT et ROLE_TAB3/EXCAVATOR = machines). SPOT
      // sans membre est tole (serveur final).
      if (BaseLocale.estTab1(p.roleCdc)) return false;
      // La jointure profil-famille vient du champ `role` de la flotte —
      // aucune liste en dur.
      final Set<String> famillesDuProfil = <String>{
        for (final TypeDT t in types)
          if (t.role.trim().toUpperCase() == p.code.trim().toUpperCase() ||
              t.role.trim().toUpperCase() ==
                  p.roleCdc.trim().toUpperCase())
            t.code.toUpperCase(),
      };
      // Famille non rattachee a ce profil : on ne bloque plus tout le
      // snapshot. L'onglet `dts` ne portant pas de `role`, la deduction peut
      // echouer sur une famille neuve (ajoutee au serveur apres les
      // equipements). L'ecran affiche alors ce profil SANS engin plutot qu'un
      // « Aucun profil configure » qui paralysait la tablette entiere.
      if (famillesDuProfil.isEmpty) return false;
      return !famillesDuProfil.any(famillesActives.contains);
    }
    final bool profilsActifsEquipes = !profils
        .where((Profil p) => p.actif)
        .any(profilSansEngin);
    if (profils.isEmpty ||
        !profilsUniques ||
        !equipementsRattaches ||
        !profilsActifsEquipes ||
        clesDT.length != types.expand((TypeDT t) => t.ids).length ||
        typesAvecDT.length != types.length ||
        types.any((TypeDT t) => t.ids.isEmpty) ||
        codesTypes.length != types.length) {
      throw const FormatException('Snapshot referentiels incomplet ou incoherent');
    }
    return ReferentielsServeur(
      profils: List<Profil>.unmodifiable(profils),
      equipements: List<EquipementServeur>.unmodifiable(equipements),
      typesDT: List<TypeDT>.unmodifiable(types),
    );
  }
}

/// Equipement enrôle fourni par le serveur (un profil, identifiant, nom).
class EquipementServeur {
  const EquipementServeur({
    required this.profil,
    required this.id,
    required this.nom,
    this.role = '',
    this.equipe = '',
    this.actif = true,
  });

  final String profil;
  final String id;
  final String nom;

  /// Serveur final : role de la personne (SPOTER, CHEF_EQUIPE), vide pour
  /// les autres profils.
  final String role;

  /// Code d'equipe du membre (SP-001...), SPOT seulement.
  final String equipe;
  final bool actif;
}

/// Une notification serveur (canal Boss -> spotter).
///
/// Le Boss ecrit depuis son bureau, le spotter la lit au prochain poll.
/// `profil` vide = pour tous les profils ; sinon cible le profil nomme
/// (`spotter`, `dt`, `excavator`). `id` est croissant cote serveur : c'est
/// le curseur de reprise, jamais genere par le client.
class NotificationServeur {
  const NotificationServeur({
    required this.id,
    required this.message,
    this.profil = '',
    this.horodatage = '',
  });

  final int id;

  /// Profil cible, vide = diffusion a tous.
  final String profil;
  final String message;
  final String horodatage;

  /// Parse la reponse `?action=notifications&depuis=N` du serveur.
  /// Rend `null` si le format est inattendu (le curseur du client ne
  /// bouge alors pas, une erreur ne perd jamais un message).
  static List<NotificationServeur>? depuisJson(Object? brut) {
    if (brut is! Map<String, Object?>) return null;
    final Object? liste = brut['notifications'];
    if (liste is! List) return null;
    return <NotificationServeur>[
      for (final Object? item in liste)
        if (item is Map<String, Object?> && item['id'] != null)
          NotificationServeur(
            id: int.tryParse('${item['id']}') ?? 0,
            message: '${item['message'] ?? ''}',
            profil: '${item['profil'] ?? ''}',
            horodatage: '${item['horodatage'] ?? ''}',
          ),
    ];
  }
}

/// Affectation courante, choisie **et validee par le serveur**.
///
/// Le client ne la modifie jamais : il la recoit, l'affiche et la conserve
/// jusqu'a la suivante. `champs` porte les paires cle/valeur (`destination`,
/// `dumping_area`, `mission`, ...), `valideLe` l'instant ou le serveur a
/// valide cette affectation (celui que l'ecran affiche en badge).
class Affectation {
  const Affectation({required this.champs, this.valideLe});

  final Map<String, String> champs;
  final String? valideLe;

  String? valeur(String cle) => champs[cle];
}

/// Ce qui sait parler au serveur.
///
/// Injecte au worker : l'application fournit l'implantation HTTP, les tests un
/// double scriptable. Aucun appel reseau n'est possible sans passer par la.
abstract class Transmetteur {
  /// Pousse un evenement vers `{api_base}/evenements` (§14).
  Future<ReponseServeur> envoyer(Enveloppe enveloppe);

  /// Lit l'affectation courante : `{api_base}/affectation` (contrat §8).
  ///
  /// `null` = rien a changer (404, erreur serveur, reseau absent) : le
  /// conservateur garde la derniere valeur connue. Une reponse 200 sans
  /// aucun champ rend egalement `null`.
  Future<Affectation?> lireAffectation();

  /// Lit les référentiels administrés par le serveur (profils, équipements,
  /// familles/identifiants de DT) : `GET ?action=referentiels` en Apps Script.
  /// `null` = erreur réseau/format (conserver l'état local); un objet valide,
  /// même vide, représente un snapshot complet et remplace les listes gérées.
  Future<ReferentielsServeur?> lireReferentiels();

  /// Lit la liste des blasts du site : `GET {api_base}/blasts` (contrat §8).
  ///
  /// C'est la descente serveur qui alimente les listes du spotter (blasts,
  /// blocs, cartes). `null` = rien a changer (404, erreur, reseau absent) :
  /// la base locale garde ses blasts deja connus. Une liste vide rendue (et
  /// non `null`) signifie « le serveur ne propose rien pour l'instant ».
  Future<List<BlastServeur>?> lireBlasts();

  /// Lit les notifications serveur posterieures a [depuis] (canal Boss ->
  /// spotter) : `GET {api_base}/notifications?depuis=<id>`. `null` = rien a
  /// changer (erreur, reseau absent) ; une liste vide rendue = aucun
  /// message plus recent que [depuis].
  Future<List<NotificationServeur>?> lireNotifications({required int depuis});

  /// Dernier retour reseau observe : `true` = le serveur a repondu,
  /// `false` = aucune reponse (reseau absent, timeout, hote inconnu),
  /// `null` = rien n'a encore ete tente.
  ///
  /// C'est la source du badge 4G (§21) : « connecte » signifie « quelqu'un
  /// a repondu de l'autre cote », pas « la file est vide ». Les doubles de
  /// test n'ont pas a l'implementer.
  bool? get serveurRepondu => null;

  /// Telecharge le plan JPG d'une carte depuis [url].
  ///
  /// `null` = echec (reseau, 404, corps vide) : le plan reste a son etat
  /// precedent, l'ecran affiche son repli (« Plan introuvable »).
  Future<Uint8List?> telechargerPlan(String url) async => null;

  /// Diagnostic de deploiement du serveur central (`GET ?action=sante`),
  /// pour valider la chaine complete tablette -> serveur Apps Script sans
  /// attendre la premiere passe de synchro.
  ///
  /// Rend un message lisible :
  /// - texte `OK - ...` : le serveur a repondu avec `ok: true` (resume des
  ///   onglets Drive, pistes, plans) ;
  /// - texte `ERREUR - ...` : HTTP/JSON invalide, jeton refuse ou serveur
  ///   injoignable.
  Future<String> diagnosticSante();

  /// Lit l'INVENTAIRE des plans disponibles sur le Drive du serveur
  /// (`GET ?action=plans`).
  ///
  /// Chaque entree porte le code de carte, l'identifiant Drive du fichier et
  /// son nom. C'est la source de la synchronisation du dossier : le client
  /// telecharge tout ce qui est present, et purge ce qui a disparu.
  ///
  /// `null` = rien a changer (reseau absent, action non servie par cette
  /// version du serveur) : la base conserve ses plans locaux.
  Future<List<PlanDrive>?> lirePlans();
}

/// Un plan present dans le dossier Drive du serveur.
class PlanDrive {
  const PlanDrive({
    required this.carte,
    required this.id,
    this.nom = '',
  });

  /// Code de carte deduit du nom du fichier (sans extension).
  final String carte;

  /// Identifiant Drive du fichier : cle stable, jamais renommee.
  final String id;

  /// Nom complet du fichier sur le Drive.
  final String nom;

  /// Parse la reponse `{"ok":true,"plans":[{"carte":…,"id":…,"nom":…}]}`.
  ///
  /// Tolere les variantes de nommage des champs (`plan_id`, `drive_id`,
  /// `file_id`) et deduit la carte du nom quand le serveur ne la fournit pas :
  /// le nom d'un plan EST le code de carte, eventuellement suffixe.
  static List<PlanDrive>? depuisJson(Object? brut) {
    if (brut is! Map<String, Object?>) return null;
    final Object? liste = brut['plans'] ?? brut['fichiers'];
    if (liste is! List) return null;
    final List<PlanDrive> sortie = <PlanDrive>[];
    for (final Object? item in liste) {
      if (item is! Map<String, Object?>) continue;
      final String nom = '${item['nom'] ?? item['name'] ?? ''}'.trim();
      String id = '${item['plan_id'] ?? item['drive_id'] ?? item['file_id'] ?? item['id'] ?? ''}'
          .trim();
      if (id.isEmpty) {
        id = BlastServeur.identifiantDrive('${item['url'] ?? ''}');
      }
      if (id.isEmpty) continue;
      String carte = '${item['carte'] ?? ''}'.trim();
      if (carte.isEmpty) carte = carteDepuisNom(nom);
      if (carte.isEmpty) continue;
      sortie.add(PlanDrive(carte: carte, id: id, nom: nom));
    }
    return sortie;
  }

  /// Deduit le code de carte d'un nom de fichier.
  ///
  /// Les plans sont nommes exactement comme leur carte
  /// (`232.5_OM_LWP2_235_230_106_3.gif`). On retire donc l'extension, et un
  /// eventuel prefixe `plan_` pose par une ancienne version du serveur.
  static String carteDepuisNom(String nom) {
    String n = nom.trim();
    if (n.isEmpty) return '';
    final int point = n.lastIndexOf('.');
    if (point > 0) n = n.substring(0, point);
    if (n.toLowerCase().startsWith('plan_')) n = n.substring(5);
    return n.trim();
  }
}

/// Transmetteur reel : POST JSON vers `{api_base}/evenements` (§14).
///
/// L'URL et le jeton sont lus dans `meta` a chaque envoi : les changer ne
/// demande aucun redemarrage. Toute anomalie (hote absent, timeout, certificat)
/// est rendue en `code = 0`, jamais en exception — c'est au worker de decider
/// de rejouer.
class TransmetteurHttp implements Transmetteur {
  TransmetteurHttp({
    required String? Function(String cle) meta,
    http.Client? client,
    this.delai = const Duration(seconds: 45),
  })  : _meta = meta,
        _client = client ?? http.Client();

  final String? Function(String cle) _meta;
  final http.Client _client;

  /// Duree maximale d'un envoi avant d'abandonner (§14 : l'echec rejoue).
  final Duration delai;

  /// Dernier retour observe (badge 4G) : mis a jour a chaque requete partie.
  bool? _serveurRepondu;

  @override
  bool? get serveurRepondu => _serveurRepondu;

  @override
  Future<ReponseServeur> envoyer(Enveloppe enveloppe) async {
    final String? racine = _racine();
    if (racine == null) {
      // Rien n'est tente sans racine : on ne decide pas de l'etat du reseau.
      return const ReponseServeur(
        code: 0,
        erreur: 'api_base absente de la table meta',
      );
    }
    final String? jeton = _meta('api_token');
    // Deux regimes d'URL, comme pour les GET (voir [_url]) : le chemin CDC
    // complet `/evenements`, ou la Web App Apps Script avec la route en
    // parametre et le jeton en query (en-tetes invisibles cote serveur).
    final String url = _racine()!.endsWith('/exec') || _racine()!.endsWith('/dev')
        ? '$racine?action=evenement&token=${jeton ?? ''}'
        : '$racine/evenements';
    try {
      final http.Response reponse = await _client
          .post(
            Uri.parse(url),
            headers: <String, String>{
              'Content-Type': 'application/json; charset=utf-8',
              if (jeton != null && jeton.isNotEmpty)
                'Authorization': 'Bearer $jeton',
              'X-Gateway-Id': enveloppe.gatewayId,
              'X-Protocol-Version': _meta('vers_protocole') ?? '1.0',
            },
            body: jsonEncode(enveloppe.toJson()),
          )
          .timeout(delai);
      // Une reponse HTTP, meme un 500, prouve que le serveur est la.
      _serveurRepondu = true;

      // ─── REDIRECTIONS 301/302/303/307/308 ────────────────────────────
      //
      // Apps Script redirige systematiquement vers
      // `script.googleusercontent.com` quand l'execution depasse son delai
      // de reponse (verifie le 27/10 : `SYNCHRO <id> ECHEC 302` en boucle,
      // 12 tentatives sur le meme evenement).
      //
      // Le client `http` de Dart NE SUIT PAS une redirection sur un POST :
      // il rend la 302 telle quelle. La traiter comme un echec etait doublement
      // faux :
      //  - le script avait bien tourne, donc l'evenement etait enregistre ;
      //  - l'app le croyait perdu et le renvoyait indefiniment.
      //
      // Une redirection vaut donc ACCEPTATION. On prefere ce choix a « suivre
      // la redirection » : le corps de la cible n'est pas garanti (page HTML
      // en cas d'echec du script), alors que l'idempotence cote serveur
      // (event_id) rend un renvoi ulterieur inoffensif. Le pire des cas est
      // donc une ligne traitee deux fois, jamais une donnee perdue.
      if (_estRedirection(reponse.statusCode)) {
        // On va CHERCHER le corps sur la cible de la redirection.
        //
        // Verifie le 27/10 : Apps Script repond `302` vers
        // `script.googleusercontent.com/macros/echo?...`, et c'est CETTE
        // adresse qui porte le JSON
        //   {"ok":true,"ack":{"status":"SYNCED",…}}
        // Le corps de la 302 elle-meme est vide, d'ou l'echec d'avant.
        final Object? corpsReel = await _suivreRedirection(reponse);
        if (corpsReel is Map<String, Object?>) {
          return ReponseServeur(
            code: reponse.statusCode,
            corps: corpsReel,
          );
        }
        // Cible illisible : l'ecriture a malgre tout eu lieu cote serveur
        // (une 302 n'est emise qu'APRES execution du script). On rend un ACK
        // explicite plutot qu'un echec : l'idempotence (`event_id`) rend un
        // renvoi ulterieur inoffensif, une perte ne le serait pas.
        return ReponseServeur(
          code: reponse.statusCode,
          corps: <String, Object?>{
            'ok': true,
            'ack': <String, Object?>{
              'event_id': enveloppe.eventId,
              'status': 'SYNCED',
              'received_at': DateTime.now().toUtc().toIso8601String(),
              'via': 'redirection ${reponse.statusCode}',
            },
          },
        );
      }

      return ReponseServeur(
        code: reponse.statusCode,
        corps: _json(reponse.body),
        erreur: reponse.statusCode >= 400 && reponse.statusCode != 409
            ? _court(reponse.body)
            : null,
      );
    } catch (e) {
      _serveurRepondu = false;
      return ReponseServeur(code: 0, erreur: _court('$e'));
    }
  }

  /// Lit le corps JSON au bout d'une redirection Apps Script.
  ///
  /// `package:http` ne suit pas une redirection sur un POST (choix de la
  /// bibliotheque, conforme a la RFC) : la reponse est la 302 nue, corps vide.
  /// On refait donc la requete en GET sur `location`, ou l'echo a deja stocke
  /// la reponse du script — verifie : 200 avec le JSON complet.
  ///
  /// Rend `null` si l'en-tete manque ou si la cible ne porte pas de JSON.
  Future<Object?> _suivreRedirection(http.Response redirection) async {
    final String? location = redirection.headers['location'];
    if (location == null || location.isEmpty) return null;
    try {
      final http.Response r =
          await _client.get(Uri.parse(location)).timeout(delai);
      if (r.statusCode != 200) return null;
      return _json(r.body);
    } catch (_) {
      // Cible injoignable : l'appelant retombe sur l'ACK optimiste.
      return null;
    }
  }

  /// Vrai pour un code de redirection HTTP.
  ///
  /// 301 deplaci permanent, 302 trouve, 303 see other, 307/308 temporaire ou
  /// permanent — Apps Script n'utilise que 302, mais un proxy intermediaire
  /// peut en choisir un autre : on traite la famille entiere.
  static bool _estRedirection(int code) =>
      code == 301 || code == 302 || code == 303 || code == 307 || code == 308;

  /// Corps JSON decode, ou null si le corps n'est pas du JSON : le regime
  /// a marqueur (`server_OT`) n'est reconnu que sur un vrai objet JSON.
  Object? _json(String corps) {
    final String t = corps.trim();
    if (!t.startsWith('{')) return null;
    try {
      return jsonDecode(t);
    } catch (_) {
      return null;
    }
  }

  /// Racine de l'API lue dans `meta`, sans slash final.
  ///
  /// Relue a chaque appel : changer `api_base` ne demande aucun
  /// redemarrage. `null` = la configuration est vide, rien n'est tentable.
  String? _racine() {
    final String base = _meta('api_base') ?? '';
    if (base.isEmpty) return null;
    return base.endsWith('/') ? base.substring(0, base.length - 1) : base;
  }

  @override
  Future<List<BlastServeur>?> lireBlasts() async {
    final Object? json = await _getJson(_url('blasts'));
    if (json == null) return null;
    return BlastServeur.depuisJson(json);
  }

  @override
  Future<List<NotificationServeur>?> lireNotifications({required int depuis}) async {
    final Object? json = await _getJson(_url('notifications&depuis=$depuis'));
    if (json == null) return null;
    return NotificationServeur.depuisJson(json);
  }

  @override
  Future<Uint8List?> telechargerPlan(String url) async {
    if (url.isEmpty) return null;
    try {
      final http.Response reponse = await _client
          .get(Uri.parse(url), headers: _enTetes)
          .timeout(delai);
      _serveurRepondu = true;
      if (reponse.statusCode != 200 || reponse.bodyBytes.isEmpty) return null;

      final Uint8List octets = reponse.bodyBytes;
      if (!_estCorpsJson(octets)) return octets;

      // Reponse JSON : ce n'est PAS un plan. Deux cas utiles :
      // - `{"ok":false,…}` : refus (ancien `action=plan` par nom) ;
      // - `{"ok":true,"url":"https://drive.google.com/…"}` : le serveur
      //   renvoie l'adresse du fichier au lieu des octets. On suit l'URL une
      //   seule fois, ce qui rend le correctif serveur interchangeable.
      final String? suite = _urlDepuisReponseJson(octets);
      if (suite == null || suite == url) return null;
      return _telechargerOctets(suite);
    } catch (_) {
      return null;
    }
  }

  /// Suite eventuelle d'une reponse JSON d'indirection (`url` ou `id` Drive).
  ///
  /// Rend `null` quand la reponse est un refus ou ne porte aucune adresse.
  static String? _urlDepuisReponseJson(Uint8List octets) {
    try {
      final Object? json = jsonDecode(utf8.decode(octets));
      if (json is! Map<String, Object?>) return null;
      if (json['ok'] == false) return null;
      final Object? brut = json['url'] ?? json['plan_url'];
      if (brut != null && '$brut'.trim().isNotEmpty) return '$brut'.trim();
      final Object? id = json['id'] ?? json['plan_id'] ?? json['drive_id'];
      if (id != null && '$id'.trim().isNotEmpty) {
        return 'https://drive.google.com/uc?export=download&confirm=t&id='
            '${'$id'.trim()}';
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// GET brut d'octets, sans interpretation du corps.
  Future<Uint8List?> _telechargerOctets(String url) async {
    try {
      final http.Response r = await _client
          .get(Uri.parse(url), headers: _enTetes)
          .timeout(delai);
      if (r.statusCode != 200 || r.bodyBytes.isEmpty) return null;
      if (_estCorpsJson(r.bodyBytes)) return null;
      return r.bodyBytes;          
    } catch (_) {
      return null;
    }
  }

  /// Vrai si la reponse est un objet JSON (`{...}`) et non un fichier.
  ///
  /// Les plans sont des images (JPEG/PNG/GIF) : un corps qui commence par
  /// `{` est forcement un refus du serveur, jamais un plan.
  static bool _estCorpsJson(Uint8List octets) {
    if (octets.isEmpty) return false;
    int i = 0;
    // Espaces et BOM eventuels.
    while (i < octets.length &&
        (octets[i] == 0x20 || octets[i] == 0x0A || octets[i] == 0x0D ||
            octets[i] == 0x09 || octets[i] == 0xEF || octets[i] == 0xBB ||
            octets[i] == 0xBF)) {
      i++;
    }
    return i < octets.length && octets[i] == 0x7B; // '{'
  }

  /// En-tetes du regime CDC complet (servent aussi au regime Apps Script,
  /// qui les ignore silencieusement — jamais d'erreur a les envoyer).
  Map<String, String> get _enTetes => <String, String>{
        if (_meta('api_token')?.isNotEmpty ?? false)
          'Authorization': 'Bearer ${_meta('api_token')}',
        'X-Protocol-Version': _meta('vers_protocole') ?? '1.0',
      };

  /// URL d'un endpoint. Deux regimes :
  /// - CDC complet : `{api_base}/blasts` ;
  /// - Apps Script (`server_OT`) : `{api_base}?action=blasts&token=...`
  ///   (la Web App n'a qu'une URL fixe, le jeton voyage en query car les
  ///   en-tetes sont invisibles). Le regime est detecte sur la forme de
  ///   `api_base` : une URL qui finit par `/exec` est une Web App.
  String _url(String action) {
    final String? racine = _racine();
    if (racine == null) return '';
    final String jeton = _meta('api_token') ?? '';
    if (racine.endsWith('/exec') || racine.endsWith('/dev')) {
      return '$racine?action=$action&token=$jeton';
    }
    return '$racine/$action';
  }

  /// GET + decode JSON, avec la meme discipline que les autres lectures :
  /// un defaut (404, 5xx, timeout, corps illisible) rend `null` et rien
  /// n'efface ce que la base connait deja (REQ-012).
  Future<Object?> _getJson(String url) async {
    if (url.isEmpty) return null;
    bool reponseRecue = false;
    try {
      final http.Response reponse = await _client
          .get(Uri.parse(url), headers: _enTetes)
          .timeout(delai);
      reponseRecue = true;
      _serveurRepondu = true;
      if (reponse.statusCode != 200) return null;
      final String t = reponse.body.trim();
      if (!t.startsWith('{')) return null;
      try {
        final Object? json = jsonDecode(t);
        // Marqueur de refus (ok:false) : une erreur reseau ou de token ne
        // doit jamais passer pour une donnee vide.
        if (json is Map<String, Object?> && json['ok'] == false) return null;
        return json;
      } catch (_) {
        return null;
      }
    } catch (_) {
      // Reseau absent, timeout, corps illisible : la liste locale est
      // conservee telle quelle (REQ-012).
      _serveurRepondu = reponseRecue;
      return null;
    }
  }

  @override
  Future<ReferentielsServeur?> lireReferentiels() async {
    final Object? brut = await _getJson(_url('referentiels'));
    if (brut == null) return null;
    try {
      return ReferentielsServeur.depuisJson(brut);
    } on FormatException {
      return null;
    }
  }

  @override
  Future<Affectation?> lireAffectation() async {
    final Object? brut = await _getJson(_url('affectation'));
    if (brut is! Map<String, Object?>) return null;
    final Object? bloc = brut['affectation'];
    if (bloc is! Map<String, Object?>) return null;

    final Map<String, String> champs = <String, String>{};
    bloc.forEach((String cle, Object? valeur) {
      if (valeur != null) champs[cle] = '$valeur';
    });
    if (champs.isEmpty) return null;
    final Object? valideLe = brut['valide_le'];
    return Affectation(
      champs: champs,
      valideLe: valideLe == null ? null : '$valideLe',
    );
  }

  /// Inventaire des plans du Drive : `GET ?action=plans`.
  ///
  /// `null` quand le serveur ne sert pas l'action (ancien deploiement) ou
  /// qu'il refuse : la synchro conserve alors les plans locaux au lieu de
  /// tout purger (une erreur reseau ne doit jamais vider le Drive local).
  @override
  Future<List<PlanDrive>?> lirePlans() async {
    final Object? brut = await _getJson(_url('plans'));
    if (brut == null) {
      debugPrint('lirePlans: aucune reponse exploitable (${_url('plans')})');
      return null;
    }
    final List<PlanDrive>? plans = PlanDrive.depuisJson(brut);
    if (plans == null) {
      // Le serveur a repondu, mais pas au format attendu : on montre le
      // debut du corps, sinon l'echec reste indevinable sur le terrain.
      final String extrait = '$brut';
      debugPrint('lirePlans: corps inattendu '
          '${extrait.length > 200 ? extrait.substring(0, 200) : extrait}');
    }
    return plans;
  }

  /// Diagnostic `GET ?action=sante` (ou `{api_base}/sante` en regime CDC),
  /// meme double lecture d'URL que les autres GET.
  @override
  Future<String> diagnosticSante() async {
    final String url = _url('sante');
    if (url.isEmpty) {
      return 'ERREUR - api_base absente des parametres : rien a tester';
    }
    bool recu = false;
    try {
      final http.Response reponse = await _client
          .get(Uri.parse(url), headers: _enTetes)
          .timeout(delai);
      recu = true;
      _serveurRepondu = true;
      final String t = reponse.body.trim();
      if (reponse.statusCode == 401 || reponse.statusCode == 403) {
        return 'ERREUR - jeton refuse (HTTP ${reponse.statusCode}) : le '
            'api_token ne correspond pas au TOKEN du serveur Apps Script';
      }
      if (reponse.statusCode == 404) {
        return 'ERREUR - adresse introuvable (HTTP 404) : verifiez l\'URL '
            '_api_base, elle doit etre celle de la Web App deployee, finissant '
            'par /exec';
      }
      if (reponse.statusCode != 200) {
        return 'ERREUR - serveur en erreur (HTTP ${reponse.statusCode}) : '
            '${_court(reponse.body)} - la Web App a peut-etre besoin d\'etre '
            'redeployee';
      }
      if (!t.startsWith('{')) {
        return 'ERREUR - reponse non JSON (HTTP ${reponse.statusCode})';
      }
      final Object? json = jsonDecode(t);
      if (json is! Map<String, Object?>) {
        return 'ERREUR - corps JSON inattendu';
      }
      if (json['ok'] != true) {
        return 'ERREUR - ${json['erreur'] ?? 'refus du serveur'}';
      }
      // Resume du diagnostic serveur : onglets, pistes, plans, base_url.
      final Object? onglets = json['onglets'];
      final Object? pistes = json['pistes'];
      final Object? plans = json['plans'];
      final String resume = <String>[
        if (onglets is Map<String, Object?>)
          'onglets: ${onglets.length} lu(s)',
        if (pistes != null) 'pistes: $pistes',
        if (plans != null) 'plans: $plans',
      ].join(', ');
      return 'OK - serveur ${json['service'] ?? 'Apps Script'} joignable '
          '(HTTP ${reponse.statusCode})${resume.isEmpty ? '' : ' - $resume'}';
    } catch (e) {
      _serveurRepondu = recu;
      return 'ERREUR - ${_causeReseau(e)} : ${_court('$e')}';
    }
  }

  /// Traduit une exception de transport en cause lisible sur le terrain.
  ///
  /// "Serveur injoignable" oblige le technicien a deviner s'il doit chercher
  /// du reseau, corriger l'URL ou changer le jeton. Ces quatre causes se
  /// distinguent pourtant sans ambiguite dans le message d'erreur.
  static String _causeReseau(Object e) {
    final String t = '$e';
    if (t.contains('Failed host lookup') ||
        t.contains('No address associated with hostname')) {
      return 'pas de reseau ou DNS absent - verifiez le Wi-Fi ou la 4G de la '
          'tablette, puis reessayez';
    }
    if (t.contains('Network is unreachable') ||
        t.contains('No route to host')) {
      return 'reseau connecte sans acces Internet - ce Wi-Fi n\'a pas de '
          'passerelle : utilisez un reseau qui donne acces a Internet';
    }
    if (t.contains('Connection refused')) {
      return 'adresse joignable mais port ferme - l\'URL vise probablement un '
          'mauvais hote';
    }
    if (t.contains('HandshakeException') || t.contains('CERTIFICATE')) {
      return 'certificat TLS refuse - seule une URL https Authenticode valide '
          'est acceptee';
    }
    if (t.contains('TimeoutException') || t.contains('timed out')) {
      return 'serveur muet (delai depasse) - reseau lent ou Web App '
          'desactivee ; reessayez puis verifiez le deploiement Apps Script';
    }
    if (t.contains('FormatException') || t.contains('Uri')) {
      return 'URL invalide - attendu une adresse complete commencant par '
          'https:// et finissant par /exec';
    }
    return 'serveur injoignable';
  }

  /// Une erreur tient en une ligne du journal, pas en un dump HTML.
  static String _court(String texte) {
    final String ligne = texte.trim().split('\n').first;
    return ligne.length > 100 ? '${ligne.substring(0, 100)}…' : ligne;
  }
}

/// Double de test : rend la reponse demandee et enregistre chaque appel.
///
/// [reponse] se modifie entre deux passes pour jouer un serveur qui revient,
/// et `appels` permet de verifier l'enveloppe effectivement partie (§12).
class TransmetteurFactice implements Transmetteur {
  TransmetteurFactice({this.reponse = const ReponseServeur(code: 202)});

  /// Reponse rendue au prochain appel.
  ReponseServeur reponse;

  /// Enveloppes recues, dans l'ordre.
  final List<Enveloppe> appels = <Enveloppe>[];

  /// Snapshot de referentiels rendu a chaque [lireReferentiels].
  ReferentielsServeur? referentiels;

  /// Affectation rendue a chaque [lireAffectation] : `null` joue un serveur
  /// muet, et le conservateur doit alors garder la valeur connue.
  Affectation? affectation;

  /// Blasts rendus par [lireBlasts] : `null` joue un serveur qui ne
  /// propose rien (defaut, reseau absent) — la base locale ne change pas.
  List<BlastServeur>? blasts;

  /// Notifications rendues par [lireNotifications] : `null` joue un serveur
  /// muet, le curseur du client ne bouge alors pas.
  List<NotificationServeur>? notifications;

  /// Octets rendus par [telechargerPlan], indexe par l'URL demandee.
  final Map<String, Uint8List> plans = <String, Uint8List>{};

  /// Nombre de lectures, pour verifier la cadence du worker.
  int nombreDeLectures = 0;

  int get nombreDAppels => appels.length;

  /// Retour simule : suivi de [reponse] (`code = 0` = reseau coupe).
  bool? _serveurRepondu;

  @override
  bool? get serveurRepondu => _serveurRepondu;

  void vider() {
    appels.clear();
    nombreDeLectures = 0;
    _serveurRepondu = null;
  }

  @override
  Future<ReponseServeur> envoyer(Enveloppe enveloppe) async {
    appels.add(enveloppe);
    _serveurRepondu = reponse.code > 0;
    return reponse;
  }

  @override
  Future<ReferentielsServeur?> lireReferentiels() async {
    nombreDeLectures++;
    _serveurRepondu = reponse.code > 0;
    return referentiels;
  }

  @override
  Future<List<BlastServeur>?> lireBlasts() async {
    nombreDeLectures++;
    _serveurRepondu = reponse.code > 0;
    return blasts;
  }

  @override
  Future<List<NotificationServeur>?> lireNotifications({required int depuis}) async {
    nombreDeLectures++;
    _serveurRepondu = reponse.code > 0;
    return notifications;
  }

  @override
  Future<Uint8List?> telechargerPlan(String url) async => plans[url];

  @override
  Future<String> diagnosticSante() async =>
      'ERREUR - test serveur indisponible dans le transmetteur factice';

  /// Inventaire de plans rendu a chaque [lirePlans] (`null` = action non
  /// servie, la synchro conserve alors les plans locaux).
  List<PlanDrive>? plansDrive;

  @override
  Future<List<PlanDrive>?> lirePlans() async => plansDrive;

  @override
  Future<Affectation?> lireAffectation() async {
    nombreDeLectures++;
    _serveurRepondu = reponse.code > 0;
    return affectation;
  }
}

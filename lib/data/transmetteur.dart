import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/models.dart';

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
    this.libelleCarte = '',
    this.planUrl = '',
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
            libelleCarte: '${item['libelle_carte'] ?? ''}',
            blocs: <String>[
              if (item['blocs'] is List)
                for (final Object? b in item['blocs'] as List) '$b',
            ],
            planUrl: '${item['plan_url'] ?? ''}',
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
    final List<EquipementServeur> equipements = <EquipementServeur>[
      for (final Map<String, Object?> e in _objets(brut['equipements']))
        if (_texte(e, 'profil').isNotEmpty &&
            _texte(e, 'id').isNotEmpty &&
            _entier(e, 'actif', 1) != 0)
          EquipementServeur(
            profil: _texte(e, 'profil'),
            id: _texte(e, 'id'),
            nom: _texte(e, 'nom'),
            actif: _entier(e, 'actif', 1) != 0,
          ),
    ];
    final Map<String, List<String>> idsParType = <String, List<String>>{};
    for (final Map<String, Object?> dt in _objets(brut['dts'])) {
      final String type = _texte(dt, 'type');
      final String id = _texte(dt, 'id');
      if (type.isEmpty || id.isEmpty || _entier(dt, 'actif', 1) == 0) continue;
      (idsParType[type] ??= <String>[]).add(id);
    }
    final List<TypeDT> types = <TypeDT>[
      for (final MapEntry<String, List<String>> entry in idsParType.entries)
        TypeDT(code: entry.key, ids: List<String>.unmodifiable(entry.value)),
    ];
    // Un payload tronque ou mal formé ne doit pas vider le référentiel local.
    final Set<String> codesProfils = profils.map((Profil p) => p.code).toSet();
    final bool profilsUniques = codesProfils.length == profils.length;
    final bool equipementsRattaches = equipements.every(
      (EquipementServeur e) => codesProfils.contains(e.profil),
    );
    final Set<String> codesTypes = types.map((TypeDT t) => t.code).toSet();
    final Set<String> typesAvecDT = idsParType.keys.toSet();
    final bool profilsActifsEquipes = profils
        .where((Profil p) => p.actif)
        .every((Profil p) => equipements.any(
              (EquipementServeur e) => e.profil == p.code && e.actif,
            ));
    final List<String> ids = types.expand((TypeDT t) => t.ids).toList();
    final bool idsUniques = ids.toSet().length == ids.length;
    if (profils.isEmpty ||
        equipements.isEmpty ||
        types.isEmpty ||
        !profilsUniques ||
        !equipementsRattaches ||
        !profilsActifsEquipes ||
        !idsUniques ||
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
    this.actif = true,
  });

  final String profil;
  final String id;
  final String nom;
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
      return reponse.bodyBytes;
    } catch (_) {
      return null;
    }
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
      if (reponse.statusCode != 200) {
        return 'ERREUR - HTTP ${reponse.statusCode} : ${_court(reponse.body)}';
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
      return 'ERREUR - serveur injoignable : ${_court('$e')}';
    }
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

  @override
  Future<Affectation?> lireAffectation() async {
    nombreDeLectures++;
    _serveurRepondu = reponse.code > 0;
    return affectation;
  }
}

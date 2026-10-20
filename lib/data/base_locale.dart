import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../models/models.dart';
import '../communication/position/service_position.dart';
import 'transmetteur.dart';

/// Base de donnees locale de l'application.
///
/// Deux regimes coexistent :
/// - **persistee** : [ouvrir] a reussi, un fichier SQLite est ouvert ; chaque
///   ecriture met d'abord l'etat en memoire a jour (l'interface reste
///   synchrone), puis la replicate sur disque dans une file ordonnee ;
/// - **en memoire** : aucune base disponible (pas de canal platform, environ-
///   ment de test) ; les seeds servent de donnees de depart et rien ne survit
///   a l'arret de l'application.
///
/// Tables (CDC §13, §12, §9, §23) :
/// - `meta`        : versions application / protocole / modele (§23)
/// - `profils`, `equipements`, `types_dt`, `ids_dt` : snapshot serveur
/// - `cartes`, `positions` : referentiels du site
/// - `blasts`, `blocs`, `lignes` : le domaine du spotter
/// - `journal`     : preuve des ecritures acceptees
/// - `evenements`  : file PENDING / SENDING / SYNCED (REQ-014, §14)
/// - `affectation` : destination / dumping area choisies par le serveur
class BaseLocale {
  /// Constructeur public : trivial, delegue immediatement a [_production] pour
  /// les valeurs reelles. Le parametre `blasts` reste inject able uniquement
  /// pour les tests : en production, [blastsDemo] n'est JAMAIS appele (sa
  /// signature est `@visibleForTesting`) et la liste par defaut est vide.
  ///
  /// La liste par defaut doit rester **modifiable** : [_recharger] la vide et
  /// la recharge depuis le disque (`const []` planterait sur `clear()`).
  BaseLocale({List<Blast>? blasts}) : this._production(blasts: blasts);

  /// Constructeur prive : definit les valeurs reelles (vides en production,
  /// injectees par le snapshot serveur a la premiere synchronisation). Les
  /// seeds de tests (libelles, coordonnees, blasts) ne sont JAMAIS appeles
  /// d'ici : ils vivent dans [blastsDemo] (et eventuellement un futur
  /// [fixturesDemo]) et restent confines aux cas de test.
  ///
  /// Toute nouvelle initialisation doit arriver ICI et nulle part ailleurs :
  /// la separation constructeur / seeds garantit qu'aucune constante de demo
  /// ne peut fuiter dans la base reelle.
  BaseLocale._production({List<Blast>? blasts})
      : _typesDT = <TypeDT>[],
        _carteLabel = _carteLabelsInit(),
        _positions = _positionsInit(),
        _equipements = <String, List<({String id, String nom})>>{},
        blasts = blasts ?? <Blast>[];

  /// Version du modele de donnees (CDC §23). Toute evolution du schema passe
  /// par une incrementation ici : [openDatabase] declenche alors [_versionner].
  ///
  /// - v1 : schema initial ;
  /// - v2 : `evenements.gateway_id` (enveloppe §12) et
  ///   `evenements.prochaine_tentative` (rejeu §14) ;
  /// - v3 : `equipements.nom` alimente le menu « Name » de la connexion ;
  /// - v4 : table `affectation`, destination/dumping area fournies par le
  ///   serveur (aucune saisie locale) ;
  /// - v5 : table `profils` et `equipements.profil` : le login lit ses
  ///   boutons dans la base au lieu d'une enum codee en dur (§2.3) ;
  /// - v6 : `blocs.verrouille` : le verrou porte sur la paire (blast, bloc),
  ///   plus sur le blast entier ; la colonne `blasts.verrouille` n'est plus
  ///   ecrite (elle reste en place sur les anciens fichiers, sans usage).
  /// - v7 : table `notifications` : canal serveur -> tablette (le Boss du
  ///   bureau y depose des messages que le spotter lit au prochain poll) ;
  /// - v8 : les referentiels profils, equipements et familles/DT sont servis
  ///   par le serveur et remplacent leurs valeurs locales.
  static const int versionModele = 8;

  /// Roles CDC (REQ-002) : les trois valeurs possibles a l'enrolement.
  static const String roleTab1 = 'ROLE_TAB1';
  static const String roleTab2 = 'ROLE_TAB2';
  static const String roleTab3 = 'ROLE_TAB3';

  /// Vrai si [role] designe le Spotter (ROLE_TAB1, SPOT ou SPOTTER).
  static bool estTab1(String role) {
    final String r = role.toUpperCase();
    return r == roleTab1 || r == 'SPOT' || r == 'SPOTTER';
  }

  /// Vrai si [role] designe le chauffeur DT (ROLE_TAB2 ou DT).
  static bool estTab2(String role) {
    final String r = role.toUpperCase();
    return r == roleTab2 || r == 'DT';
  }

  /// Vrai si [role] designe l'excavatrice (ROLE_TAB3, EXCAVATOR ou EXCAVATRICE).
  static bool estTab3(String role) {
    final String r = role.toUpperCase();
    return r == roleTab3 || r == 'EXCAVATOR' || r == 'EXCAVATRICE';
  }

  /// Vrai si [role] designe le spotter (SPOTTER ou SPOT).
  ///
  /// Le spotter n'embarque **aucun recepteur GNSS** : sa tablette ne sait pas
  /// se localiser. Le service de position ne doit donc pas etre demarre pour
  /// lui, sinon chaque « mesure » reellement indisponible produit un
  /// `GPS_UPDATE` inutile dans la file d'evenements — et le compteur
  /// d'attente affiche des evenements que l'utilisateur n'a jamais crees.
  static bool estSpotter(String role) {
    final String r = role.toUpperCase();
    return r == 'SPOTTER' || r == 'SPOT';
  }

  /// Versions visibles par l'application, ecrites dans `meta` a la creation.
  static const Map<String, String> versions = <String, String>{
    'vers_app': '1.0.0',
    'vers_protocole': '1.0',
    'vers_modele': '8.0',
  };

  /// Modes d'envoi du bouton « Envoyer », choisis dans `meta.envoi_mode`
  /// (cle documentee dans PARAMETRES.md) :
  /// - [envoiModeBlast] : tout le blast, tous ses blocs verrouilles ;
  /// - [envoiModeBloc] : le seul bloc courant, verrouille ;
  /// - [envoiModeVerrouilles] : tous les blocs verrouilles du blast.
  static const String envoiModeBlast = 'blast';
  static const String envoiModeBloc = 'bloc';
  static const String envoiModeVerrouilles = 'verrouilles';

  /// Mode d'envoi courant, lu dans `meta` a chaque appel (cle absente =
  /// [envoiModeBlast], comportement historique).
  String get envoiMode {
    final String brut = _meta['envoi_mode'] ?? '';
    switch (brut) {
      case envoiModeBloc:
      case envoiModeVerrouilles:
        return brut;
      default:
        return envoiModeBlast;
    }
  }

  /// Categories DT, remplacées atomiquement par le snapshot serveur valide.
  List<TypeDT> _typesDT;

  /// Libelle lisible des codes de carte (A1 -> Fosse A - niveau 1).
  final Map<String, String> _carteLabel;

  /// Points geographiques connus : depart du DT, destinations, dumping areas.
  ///
  /// Cle = code du point (celui que la session porte dans `destination` ou
  /// `dumpingArea`), valeur = WGS84. La carte de suivi ne lit que la.
  final Map<String, ({double lat, double lng})> _positions;

  final List<Blast> blasts;

  /// Journal des ecritures. Sans vraie base sur disque, c'est ce qui prouve
  /// que le verrouillage a bien enregistre le travail du blast.
  final List<String> journal = [];

  /// Motif du dernier refus, pour que l'ecran puisse l'expliquer.
  String? refusEnCours;

  Database? _db;
  Future<void> _ouverture = Future<void>.value();
  Future<void> _fileEcritures = Future<void>.value();

  /// Equipements enrroles, par code de profil (REQ-002), remplaces par snapshot.

  ///
  /// L'identifiant et le nom voyagent ensemble : ce sont les deux colonnes de
  /// la meme ligne `equipements`. Les deux menus de la connexion sont donc
  /// alimentes par la meme source et ne peuvent pas proposer une paire
  /// inexistante. La cle est le code du profil, sa colonne `role` porte le
  /// role CDC de la meme ligne.
  final Map<String, List<({String id, String nom})>> _equipements;

  /// Profils proposes au login (CDC §2.3), lus depuis le dernier snapshot
  /// serveur validé. Vide tant qu'aucun snapshot n'a été reçu.
  List<Profil> _profils = <Profil>[];

  /// Versions lues dans la table `meta`, renseinees des le demarrage (§23).
  final Map<String, String> _meta = <String, String>{...versions};

  /// Evenements en attente de transmission (PENDING).
  ///
  /// Compteur tenu en memoire de part et d'autre : incremente a chaque ecriture
  /// metier, recalcule sur disque quand la base est chargee.
  int _enAttente = 0;

  /// Affectation courante, fournie par le serveur (destination, dumping
  /// area, mission) : cle -> (valeur, horodatage de validation).
  ///
  /// Vide tant que le serveur n'a rien renvoye : l'ecran affiche alors
  /// « en attente » plutot que d'inventer un point. Rien n'ecrit ici depuis
  /// l'interface — seul [enregistrerAffectation] remplit la table.
  final Map<String, ({String valeur, String? horodatage})> _affectation =
      <String, ({String valeur, String? horodatage})>{};

  /// Identifiant de l'appareil inscrit comme `source_device` (CDC §12).
  String _appareil = '';

  /// Identifiant de la passerelle qui relaie les evenements (`gateway_id`).
  ///
  /// Tant qu'aucune passerelle n'est declaree, une tablette qui ecrit ses
  /// propres evenements est sa propre source : les deux colonnes coincident.
  String _passerelle = '';

  /// Vrai quand un fichier est ouvert et que les ecritures sont sauvegardees.
  bool get estPersistee => _db != null;

  // ----------------------------------------------------------------- ouverture

  /// Ouvre le fichier local, cree le schema au premier lancement, recharge les
  /// donnees depuis le disque.
  ///
  /// Idempotente et jamais rejetante : si la base est inaccessible, l'app
  /// continue en memoire plutot que de s'arreter sur un ecran blanc.
  Future<void> ouvrir({String? chemin}) => _ouverture = _ouverture.then(
        (_) => _ouvrirBase(chemin),
      );

  Future<void> _ouvrirBase(String? chemin) async {
    if (_db != null) return;
    try {
      final String dossier = await getDatabasesPath();
      final Database db = await openDatabase(
        chemin ?? '$dossier/ore_tracking.db',
        version: versionModele,
        onConfigure: (Database db) => db.execute('PRAGMA foreign_keys = ON'),
        onCreate: _creer,
        onUpgrade: _versionner,
      );
      _db = db;
      // Migration legere : la colonne `carte` sur `blocs` a ete ajoutee apres
      // coup. Sur une base deja creee, ALTER TABLE est idempotent (échec
      // silencieux si la colonne existe).
      try {
        await db.execute(
          "ALTER TABLE blocs ADD COLUMN carte TEXT NOT NULL DEFAULT '';",
        );
      } catch (_) {}
      // Les blocs herites n'ont pas de carte : ils pointeraient tous sur un RL
      // vide. On les purge ; la prochaine synchro serveur les recree avec leur
      // RL exact (blocs_par_carte). Les lignes deja saisies sont conservees
      // par la synchro : seul le rattachement RL est refait.
      final int orphelins = Sqflite.firstIntValue(
            await db.rawQuery(
              "SELECT COUNT(*) FROM blocs WHERE carte IS NULL OR carte = ''",
            ),
          ) ??
          0;
      if (orphelins > 0) {
        await db.delete(
          'blocs',
          where: "carte IS NULL OR carte = ''",
        );
        debugPrint('Migration blocs : $orphelins bloc(s) sans RL supprime(s)');
      }
      await _recharger(db);
      // Le compteur d'attente doit refleter le DISQUE, pas l'etat d'il y a
      // une session. Sans ce comptage, la supervision affichait 0 evenement
      // en attente apres un redemarrage, alors que la file en contenait
      // encore : impossible de savoir s'il restait quelque chose a envoyer.
      await _recalculerAttente(db);
    } catch (e) {
      _db = null;
      debugPrint('Base locale indisponible (fonctionnement en memoire) : $e');
    }
  }

  /// Ferme le fichier apres avoir vide la file d'ecritures.
  Future<void> fermer() async {
    await attendreEcritures();
    await _db?.close();
    _db = null;
    _ouverture = Future<void>.value();
  }

  /// Prochaine ecriture terminee : les tests l'appellent pour relire le disque.
  Future<void> attendreEcritures() => _fileEcritures;

  // -------------------------------------------------------------------- schema

  Future<void> _creer(Database db, int version) async {
    await db.execute('''
      CREATE TABLE meta (
        cle TEXT PRIMARY KEY,
        valeur TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE equipements (
        role TEXT NOT NULL,
        profil TEXT NOT NULL DEFAULT '',
        id TEXT NOT NULL,
        nom TEXT NOT NULL DEFAULT '',
        PRIMARY KEY (role, id)
      )
    ''');
    await db.execute('''
      CREATE TABLE cartes (
        code TEXT PRIMARY KEY,
        libelle TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE positions (
        code TEXT PRIMARY KEY,
        lat REAL NOT NULL,
        lng REAL NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE types_dt (
        code TEXT NOT NULL PRIMARY KEY
      )
    ''');
    await db.execute('''
      CREATE TABLE ids_dt (
        code_type TEXT NOT NULL,
        id TEXT NOT NULL,
        PRIMARY KEY (code_type, id)
      )
    ''');
    await db.execute('''
      CREATE TABLE blasts (
        numero TEXT PRIMARY KEY,
        carte TEXT NOT NULL,
        plan TEXT NOT NULL,
        envoye INTEGER NOT NULL DEFAULT 0
      )
    ''');
    // v6 : le verrou vit sur la paire (blast, bloc), pas sur le blast entier.
    // Un meme numero de bloc peut exister sur deux RL (cartes) differentes du
    // meme blast : la cle d'unicite inclut donc la carte.
    await db.execute('''
      CREATE TABLE blocs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        blast TEXT NOT NULL,
        numero TEXT NOT NULL,
        carte TEXT NOT NULL DEFAULT '',
        verrouille INTEGER NOT NULL DEFAULT 0,
        UNIQUE (blast, numero, carte)
      )
    ''');
    await db.execute('''
      CREATE TABLE lignes (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        bloc_id INTEGER NOT NULL,
        time TEXT NOT NULL,
        dt TEXT NOT NULL,
        id_dt TEXT NOT NULL,
        has_picture INTEGER NOT NULL DEFAULT 0,
        photo BLOB,
        comment TEXT NOT NULL DEFAULT ''
      )
    ''');
    await db.execute('''
      CREATE TABLE journal (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        horodatage TEXT NOT NULL,
        requete TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE evenements (
        event_id TEXT PRIMARY KEY,
        gateway_id TEXT NOT NULL DEFAULT '',
        source_device TEXT NOT NULL,
        event_type TEXT NOT NULL,
        timestamp TEXT NOT NULL,
        payload TEXT NOT NULL,
        rssi INTEGER,
        etat TEXT NOT NULL DEFAULT 'PENDING',
        tentatives INTEGER NOT NULL DEFAULT 0,
        prochaine_tentative INTEGER
      )
    ''');
    await db.execute('CREATE INDEX idx_evenements_etat ON evenements (etat)');
    // Destination et dumping area : paires cle/valeur fournies par le
    // serveur. La table garde l'horodatage de validation pour l'ecran.
    await db.execute(_tableAffectation);
    // Profils (§2.3) : boutons, titres et rangs du login.
    await db.execute(_tableProfils);
    // Notifications serveur (v7) : canal Boss -> tablette.
    await db.execute(_tableNotifications);
    await _semer(db);
  }

  /// Table profils (v5). `IF NOT EXISTS` : voir [_tableAffectation].
  static const String _tableProfils = '''
      CREATE TABLE IF NOT EXISTS profils (
        code TEXT PRIMARY KEY,
        libelle TEXT NOT NULL,
        titre TEXT NOT NULL DEFAULT '',
        role_cdc TEXT NOT NULL,
        icone TEXT NOT NULL DEFAULT '',
        ordre INTEGER NOT NULL DEFAULT 0,
        actif INTEGER NOT NULL DEFAULT 1
      )
    ''';

  /// Table affectation (v4). `IF NOT EXISTS` : un fichier deja a jour qui
  /// repasse par la migration (ex. retour de version, restauration) ne doit
  /// pas exploser sur une table qu'il possede deja.
  static const String _tableAffectation = '''
      CREATE TABLE IF NOT EXISTS affectation (
        cle TEXT PRIMARY KEY,
        valeur TEXT NOT NULL,
        source TEXT NOT NULL DEFAULT 'SERVEUR',
        horodatage TEXT
      )
    ''';

  /// Table notifications (v7) : messages deposés par le serveur (le Boss au
  /// bureau), lus par la tablette au prochain poll. Le curseur `derniere_id`
  /// vit dans `meta` : la reprise apres coupure ne repart jamais de zero.
  static const String _tableNotifications = '''
      CREATE TABLE IF NOT EXISTS notifications (
        id INTEGER PRIMARY KEY,
        profil TEXT NOT NULL DEFAULT '',
        message TEXT NOT NULL,
        horodatage TEXT NOT NULL DEFAULT ''
      )
    ''';

  /// Evolution du schema (CDC §23 : version du modele de donnees).
  ///
  /// [de] est la version du fichier ouvert : chaque palier écrit sa migration
  /// ici, sans jamais creer de table deux fois.
  Future<void> _versionner(Database db, int de, int vers) async {
    if (de < 2) {
      // v2 : l'enveloppe du §12 porte la passerelle, et le rejeu du §14 doit
      // savoir a quand remettre un essai sans harceler le serveur.
      await db.execute(
        "ALTER TABLE evenements ADD COLUMN gateway_id TEXT NOT NULL DEFAULT ''",
      );
      await db.execute(
        'ALTER TABLE evenements ADD COLUMN prochaine_tentative INTEGER',
      );
      // La version visible (§23) suit le schema : sinon `meta` dirait encore
      // 1.0 pendant que la table porte deja les colonnes de la v2.
      await db.insert(
        'meta',
        <String, Object?>{
          'cle': 'vers_modele',
          'valeur': '2.0',
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    if (de < 3) {
      // v3 : la colonne nom existe deja dans le schema local; elle sera
      // renseignee par le snapshot du serveur, sans injecter de valeurs en dur.
      await db.insert(
        'meta',
        <String, Object?>{'cle': 'vers_modele', 'valeur': '3.0'},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    if (de < 4) {
      // v4 : le serveur choisit la destination et la dumping area. La table
      // n'est pas encore remplie : le premier passage de 4G la remplit.
      await db.execute(_tableAffectation);
      await db.insert(
        'meta',
        <String, Object?>{
          'cle': 'vers_modele',
          'valeur': '4.0',
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    if (de < 5) {
      // v5 : tables de profils et lien profil/equipement.
      await db.execute(_tableProfils);
      final List<Map<String, Object?>> colonnes = await db.rawQuery(
        'PRAGMA table_info(equipements)',
      );
      if (!colonnes.any((row) => row['name'] == 'profil')) {
        await db.execute(
          "ALTER TABLE equipements ADD COLUMN profil TEXT NOT NULL DEFAULT ''",
        );
      }
      await db.insert(
        'meta',
        <String, Object?>{'cle': 'vers_modele', 'valeur': '5.0'},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    if (de < 6) {
      // v6 : le verrou descend du blast vers chaque bloc (paire blast/bloc).
      // La colonne `blasts.verrouille` reste en place (elle ne gene pas) mais
      // n'est plus lue ni ecrite : l'etat veritable est sur chaque ligne
      // `blocs`. Garde-fou `PRAGMA table_info` : un fichier deja porte de la
      // colonne ne doit pas planter sur un ADD COLUMN duplique.
      final List<Map<String, Object?>> infos = await db.rawQuery(
        'PRAGMA table_info(blocs)',
      );
      final bool dejaLa = infos.any((row) => row['name'] == 'verrouille');
      if (!dejaLa) {
        await db.execute(
          'ALTER TABLE blocs ADD COLUMN verrouille INTEGER NOT NULL DEFAULT 0',
        );
      }
      await db.insert(
        'meta',
        <String, Object?>{
          'cle': 'vers_modele',
          'valeur': '6.0',
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    if (de < 7) {
      // v7 : canal de notifications serveur (Boss -> tablette).
      await db.execute(_tableNotifications);
      await db.insert(
        'meta',
        <String, Object?>{
          'cle': 'vers_modele',
          'valeur': '7.0',
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    if (de < 8) {
      // v8 : les listes de reference sont resynchronisees depuis le serveur;
      // les structures locales restent compatibles, sans migration destructive.
      await db.insert(
        'meta',
        <String, Object?>{
          'cle': 'vers_modele',
          'valeur': '8.0',
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
  }

  /// Ecrit les donnees de depart dans un schema vierge.
  Future<void> _semer(Database db) async {
    final Batch batch = db.batch();
    _meta.forEach((String cle, String valeur) {
      batch.insert('meta', <String, Object?>{'cle': cle, 'valeur': valeur});
    });
    _carteLabel.forEach((String code, String libelle) {
      batch.insert('cartes', <String, Object?>{'code': code, 'libelle': libelle});
    });
    _positions.forEach(
      (String code, ({double lat, double lng}) point) {
        batch.insert(
          'positions',
          <String, Object?>{'code': code, 'lat': point.lat, 'lng': point.lng},
        );
      },
    );
    await batch.commit(noResult: true);

    // Blasts, blocs et lignes : les identifiants AUTOINCREMENT doivent etre
    // connus ligne a ligne, donc pas de lot ici. Le verrou (v6) se pose sur
    // chaque bloc ; `blasts.verrouille` n'est plus ecrite.
    for (final Blast blast in blasts) {
      await db.insert('blasts', <String, Object?>{
        'numero': blast.numero,
        'carte': blast.cartes.isNotEmpty ? blast.cartes.first : '',
        'plan': blast.plan,
        'envoye': blast.envoye ? 1 : 0,
      });
      for (final BlocTravail bloc in blast.blocs) {
        final int blocId = await db.insert('blocs', <String, Object?>{
          'blast': blast.numero,
          'numero': bloc.numero,
          'verrouille': bloc.verrouille ? 1 : 0,
        });
        // La liste porte la ligne la plus recente en tete : on inscrit dans
        // l'ordre inverse pour que `ORDER BY rowid DESC` la restitue a l'identique.
        for (final LigneBlast ligne in bloc.lignes.reversed) {
          await db.insert('lignes', _ligneValeurs(blocId, ligne));
        }
      }
    }
  }

  // ------------------------------------------------------------------ lecture

  Map<String, Object?> _ligneValeurs(int blocId, LigneBlast ligne) =>
      <String, Object?>{
        'bloc_id': blocId,
        'time': ligne.time,
        'dt': ligne.dt,
        'id_dt': ligne.idDt,
        'has_picture': ligne.hasPicture ? 1 : 0,
        'photo': ligne.photo,
        'comment': ligne.comment,
      };

  /// Remplace les donnees en memoire par celles du disque.
  Future<void> _recharger(Database db) async {
    // §24 : un envoi interrompu par un arret brutal ne doit rester ni coincé
    // en SENDING, ni invisible du compteur, ni perdu. Il repart en file.
    await db.rawUpdate(
      "UPDATE evenements SET etat = 'PENDING' WHERE etat = 'SENDING'",
    );

    _meta
      ..clear()
      ..addEntries(
        (await db.query('meta')).map(
          (row) => MapEntry<String, String>(
            row['cle']! as String,
            row['valeur']! as String,
          ),
        ),
      );

    final List<Map<String, Object?>> lignesProfils =
        await db.query('profils', orderBy: 'ordre, rowid');
    if (lignesProfils.isNotEmpty) {
      _profils
        ..clear()
        ..addAll(lignesProfils.map(_profilLigne));
    }
    final List<Map<String, Object?>> lignesTypes =
        await db.query('types_dt', orderBy: 'rowid');
    if (lignesTypes.isNotEmpty) {
      _typesDT.clear();
    }
    for (final row in lignesTypes) {
      final String code = row['code']! as String;
      final List<String> ids = (await db.query(
        'ids_dt',
        where: 'code_type = ?',
        whereArgs: <Object?>[code],
        orderBy: 'rowid',
      ))
          .map((r) => r['id']! as String)
          .toList();
      _typesDT.add(TypeDT(code: code, ids: ids));
    }

    final List<Map<String, Object?>> lignesEquipements =
        await db.query('equipements', orderBy: 'rowid');
    if (lignesEquipements.isNotEmpty) _equipements.clear();
    final Set<String> profilsServeur =
        _profils.map((Profil profil) => profil.code).toSet();
    for (final row in lignesEquipements) {
      // `profil` est la cle de lecture ; les lignes legacy sans code de profil
      // restent ignorées jusqu'au prochain snapshot serveur.
      final String code = (row['profil'] as String?) ?? '';
      if (!profilsServeur.contains(code)) continue;
      (_equipements[code] ??= <({String id, String nom})>[]).add(
        (id: row['id']! as String, nom: (row['nom'] as String?) ?? ''),
      );
    }

    _carteLabel
      ..clear()
      ..addEntries(
        (await db.query('cartes')).map(
          (row) => MapEntry<String, String>(
            row['code']! as String,
            row['libelle']! as String,
          ),
        ),
      );

    _positions
      ..clear()
      ..addEntries(
        (await db.query('positions')).map(
          (row) => MapEntry<String, ({double lat, double lng})>(
            row['code']! as String,
            (lat: (row['lat']! as num).toDouble(), lng: (row['lng']! as num).toDouble()),
          ),
        ),
      );

    final List<Blast> relus = <Blast>[];
    for (final row in await db.query('blasts', orderBy: 'rowid')) {
      final String carteBrut = row['carte']! as String;
      final List<String> cartes = carteBrut.contains(',')
          ? carteBrut
              .split(',')
              .map((s) => s.trim())
              .where((s) => s.isNotEmpty)
              .toList(growable: true)
          : <String>[carteBrut];
      final String premiereCarte =
          cartes.isNotEmpty ? cartes.first : carteBrut;
      final Blast blast = Blast(
        numero: row['numero']! as String,
        cartes: cartes,
        plan: row['plan']! as String,
        envoye: (row['envoye']! as int) != 0,
        blocs: <BlocTravail>[],
      );
      final rowsBlocs = await db.query(
        'blocs',
        where: 'blast = ?',
        whereArgs: <Object?>[blast.numero],
        orderBy: 'rowid',
      );
      for (final rowBloc in rowsBlocs) {
        final String carteBloc =
            ((rowBloc['carte'] as String?) ?? '').trim();
        final BlocTravail bloc = BlocTravail(
          numero: rowBloc['numero']! as String,
          // Le bloc se souvient de SA carte (son RL) ; les anciens blocs sans
          // carte retombent sur la premiere carte du blast.
          carte: carteBloc.isNotEmpty ? carteBloc : premiereCarte,
          verrouille: (rowBloc['verrouille']! as int) != 0,
        );
        final rowsLignes = await db.query(
          'lignes',
          where: 'bloc_id = ?',
          whereArgs: <Object?>[rowBloc['id']! as int],
          orderBy: 'rowid DESC',
        );
        for (final rowLigne in rowsLignes) {
          bloc.lignes.add(
            LigneBlast(
              time: rowLigne['time']! as String,
              dt: rowLigne['dt']! as String,
              idDt: rowLigne['id_dt']! as String,
              hasPicture: (rowLigne['has_picture']! as int) != 0,
              photo: _octets(rowLigne['photo']),
              comment: (rowLigne['comment'] as String?) ?? '',
            ),
          );
        }
        blast.blocs.add(bloc);
      }
      relus.add(blast);
    }
    blasts
      ..clear()
      ..addAll(relus);

    _affectation.clear();
    for (final row in await db.query('affectation', orderBy: 'rowid')) {
      _affectation[row['cle']! as String] = (
        valeur: row['valeur']! as String,
        horodatage: row['horodatage'] as String?,
      );
    }

    // Notifications serveur : relues du disque, le curseur `meta` dit ou en
    // est la lecture — les vieux messages ne sont jamais rejoues.
    await _rechargerNotifications(db);

    final rowsJournal = await db.query('journal', orderBy: 'rowid DESC');
    journal
      ..clear()
      ..addAll(
        rowsJournal.map((row) {
          final String horodatage = row['horodatage']! as String;
          return '${horodatage.substring(11, 19)}  ${row['requete']! as String}';
        }),
      );

    _enAttente = Sqflite.firstIntValue(
          await db.rawQuery(
            'SELECT COUNT(*) FROM evenements WHERE etat = ?',
            <Object?>['PENDING'],
          ),
        ) ??
        0;
  }

  static Uint8List? _octets(Object? valeur) {
    if (valeur == null) return null;
    if (valeur is Uint8List) return valeur;
    if (valeur is List<int>) return Uint8List.fromList(valeur);
    return null;
  }

  // ---------------------------------------------------------------- ecritures

  /// Replique une operation sur disque, dans l'ordre des appels.
  ///
  /// L'interface reste synchrone : la memoire est deja juste quand on revient
  /// de l'appel metier, le fichier suit dans la foulée.
  void _ecrire(Future<void> Function(Database db) operation) {
    final Database? db = _db;
    if (db == null) return;
    _fileEcritures = _fileEcritures.then((_) => operation(db)).catchError(
          (Object e) => debugPrint('Ecriture locale refusee : $e'),
        );
  }

  Future<int?> _idDuBloc(
    Database db,
    String blast,
    String numero, {
    String? carte,
  }) async {
    final bool parCarte = carte != null && carte.isNotEmpty;
    final rows = await db.query(
      'blocs',
      columns: <String>['id'],
      where: parCarte
          ? 'blast = ? AND numero = ? AND carte = ?'
          : 'blast = ? AND numero = ?',
      whereArgs: parCarte
          ? <Object?>[blast, numero, carte]
          : <Object?>[blast, numero],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['id']! as int;
  }

  /// Pose un evenement dans la file d'attente (CDC §12).
  ///
  /// `rssi` reste nul tant que la couche radio n'existe pas : la colonne est
  /// des d'ores et deja ouverte (décision C3).
  void _evenement(String type, Map<String, Object?> contenu) {
    _enAttente++;
    _ecrire(
      (Database db) => db.insert(
        'evenements',
        <String, Object?>{
          'event_id': _uuid(),
          'gateway_id': _passerelle.isEmpty ? _appareil : _passerelle,
          'source_device': _appareil,
          'event_type': type,
          'timestamp': DateTime.now().toUtc().toIso8601String(),
          'payload': jsonEncode(contenu),
          'rssi': null,
          'etat': 'PENDING',
          'tentatives': 0,
        },
      ),
    );
  }

  /// Identifiant applicatif unique (REQ-014) : UUID v4 genere sur place.
  static String _uuid() {
    final Random rng = Random.secure();
    final List<int> o = List<int>.generate(16, (_) => rng.nextInt(256));
    o[6] = (o[6] & 0x0f) | 0x40;
    o[8] = (o[8] & 0x3f) | 0x80;
    String h(int i) => o[i].toRadixString(16).padLeft(2, '0');
    return '${h(0)}${h(1)}${h(2)}${h(3)}-${h(4)}${h(5)}-${h(6)}${h(7)}-'
        '${h(8)}${h(9)}-${h(10)}${h(11)}${h(12)}${h(13)}${h(14)}${h(15)}';
  }

  // ---------------------------------------------------------------- lectures

  /// Categories de DT proposees par la premiere liste deroulante.
  List<TypeDT> get typesDT => List<TypeDT>.unmodifiable(_typesDT);

  /// Lot de numeros du type choisi, pour la seconde liste deroulante.
  ///
  /// Depend du type : la liste est filtree par la categorie, donc on ne peut
  /// pas enregistrer le numero 9 d'une categorie de 2000 tonnes sur une ligne
  /// declaree en 1500.
  List<String> idsDuType(String codeType) =>
      typeDT(codeType)?.ids ?? const <String>[];

  List<String> get numerosBlast =>
      blasts.map((blast) => blast.numero).toList();

  Blast? parNumero(String numero) {
    for (final blast in blasts) {
      if (blast.numero == numero) return blast;
    }
    return null;
  }

  /// Blocs d'un blast : alimente la liste « Select bloc ».
  List<BlocTravail> blocsDe(String numero) => parNumero(numero)?.blocs ?? [];

  String? libelleCarte(String code) => _carteLabel[code];

  /// Code du point de depart du DT : c'est de la que son trajet commence.
  static const String codeDepart = 'DEPOT';

  /// Coordonnees d'un point connu, ou null si le code n'existe pas.
  ({double lat, double lng})? positionDe(String code) => _positions[code];

  /// Codes des points geographiques connus.
  List<String> get codesPoints =>
      List<String>.unmodifiable(_positions.keys);

  TypeDT? typeDT(String code) {
    for (final type in _typesDT) {
      if (type.code == code) return type;
    }
    return null;
  }

  /// Famille d'un identifiant.
  ///
  /// Les identifiants sont non redondants : ce retour ne peut jamais etre
  /// ambigu. Sert a verifier qu'une ligne ne declare pas un DT dans une
  /// famille qui n'est pas la sienne.
  TypeDT? familleDuId(String id) {
    for (final type in _typesDT) {
      if (type.contient(id)) return type;
    }
    return null;
  }

  /// Profils configures (CDC §2.3), dans l'ordre de presentation.
  List<Profil> get profils => List<Profil>.unmodifiable(_profils);

  /// Profils reels de la colonne de connexion : `actif` retire ceux qui sont
  /// retires du service sans pour autant detruire leurs equipements.
  List<Profil> get profilsActifs => List<Profil>.unmodifiable(
        _profils.where((Profil profil) => profil.actif),
      );

  /// Profil de ce [code], ou null s'il n'existe pas.
  Profil? profil(String code) {
    for (final Profil profil in _profils) {
      if (profil.code == code) return profil;
    }
    return null;
  }

  /// Profil qui porte ce [role] CDC (REQ-002).
  ///
  /// Un role peut accueillir plusieurs profils : c'est le premier actif qui
  /// gagne, les autres restent configurables sans changer le login.
  Profil? profilDuRole(String role) {
    Profil? premier;
    for (final Profil profil in _profils) {
      if (profil.roleCdc != role) continue;
      if (profil.actif) return profil;
      premier ??= profil;
    }
    return premier;
  }

  /// Remplace atomiquement les referentiels administres par le serveur.
  ///
  /// Un snapshot incomplet est refuse avant l'ecriture; les listes memoire ne
  /// changent qu'apres la transaction SQLite.
  Future<void> appliquerReferentiels(ReferentielsServeur snapshot) async {
    if (snapshot.profils.isEmpty || snapshot.typesDT.isEmpty) {
      throw const FormatException('Referentiels serveur incomplets');
    }
    final Set<String> codesProfils = <String>{
      for (final Profil profil in snapshot.profils) profil.code,
    };
    final Set<String> codesTypes = <String>{
      for (final TypeDT type in snapshot.typesDT) type.code,
    };
    final Set<String> equipementsUniques = <String>{
      for (final EquipementServeur e in snapshot.equipements)
        '${e.profil}\u0000${e.id}',
    };
    final List<String> identifiantsDT = <String>[
      for (final TypeDT type in snapshot.typesDT) ...type.ids,
    ];
    final Set<String> identifiantsDTUniques = identifiantsDT.toSet();
    final Set<String> equipementsActifs = <String>{
      for (final EquipementServeur e in snapshot.equipements)
        if (e.actif) e.profil,
    };
    if (codesProfils.length != snapshot.profils.length ||
        codesTypes.length != snapshot.typesDT.length ||
        snapshot.equipements.any((EquipementServeur e) =>
            !codesProfils.contains(e.profil)) ||
        equipementsUniques.length != snapshot.equipements.length ||
        snapshot.typesDT.any((TypeDT type) => type.ids.isEmpty) ||
        identifiantsDTUniques.length != identifiantsDT.length ||
        snapshot.profils.any((Profil p) =>
            p.actif && !equipementsActifs.contains(p.code))) {
      throw const FormatException('Referentiels serveur incoherents');
    }
    final Database? db = _db;
    if (db != null) {
      await db.transaction((Transaction txn) async {
        await txn.delete('profils');
        await txn.delete('equipements');
        await txn.delete('types_dt');
        await txn.delete('ids_dt');
        for (final Profil profil in snapshot.profils) {
          await txn.insert('profils', _profilValeurs(profil));
        }
        for (final EquipementServeur equipement in snapshot.equipements) {
          if (!equipement.actif) continue;
          final Profil profil = snapshot.profils.firstWhere(
            (Profil p) => p.code == equipement.profil,
          );
          await txn.insert('equipements', <String, Object?>{
            'role': profil.roleCdc,
            'profil': profil.code,
            'id': equipement.id,
            'nom': equipement.nom,
          });
        }
        for (final TypeDT type in snapshot.typesDT) {
          await txn.insert('types_dt', <String, Object?>{'code': type.code});
          for (final String id in type.ids) {
            await txn.insert('ids_dt', <String, Object?>{
              'code_type': type.code,
              'id': id,
            });
          }
        }
      });
    }
    _appliquerReferentielsMemoire(snapshot);
    if (db != null) await _recharger(db);
  }

  void _appliquerReferentielsMemoire(ReferentielsServeur snapshot) {
    _profils = List<Profil>.of(snapshot.profils);
    _equipements
      ..clear()
      ..addEntries(
        snapshot.profils.map((Profil p) => MapEntry(
              p.code,
              <({String id, String nom})>[
                for (final EquipementServeur e in snapshot.equipements)
                  if (e.profil == p.code && e.actif)
                    (id: e.id, nom: e.nom),
              ],
            )),
      );
    _typesDT = List<TypeDT>.of(snapshot.typesDT);
  }

  /// Identifiants enrroles pour un profil, lus dans `equipements`.
  List<String> idsDuProfil(Profil profil) =>
      List<String>.unmodifiable(_lot(profil.code).map((e) => e.id));

  /// Identifiants enrroles pour un role (REQ-002).
  List<String> idsDuRole(String role) {
    final Profil? profil = profilDuRole(role);
    return profil == null ? const <String>[] : idsDuProfil(profil);
  }

  /// Noms affiches par le menu « Name », dans l'ordre de [idsDuProfil].
  ///
  /// Les deux listes sortent du meme parcours dans la meme table : elles ont
  /// la meme longueur et la meme disposition, quel que soit le profil.
  List<String> nomsDuProfil(Profil profil) =>
      List<String>.unmodifiable(_lot(profil.code).map((e) => e.nom));

  /// Noms affiches pour un role.
  List<String> nomsDuRole(String role) {
    final Profil? profil = profilDuRole(role);
    return profil == null ? const <String>[] : nomsDuProfil(profil);
  }

  /// Nom de l'equipement [id] enrrole sous ce profil, ou null.
  ///
  /// C'est la reference qui decide si un couple id/nom est coherent : la
  /// connexion interroge la base au lieu de deviner, et refuse les paires
  /// qui ne designent pas un seul et meme equipement.
  String? nomDuProfil(Profil profil, String id) {
    for (final ({String id, String nom}) e in _lot(profil.code)) {
      if (e.id == id) return e.nom;
    }
    return null;
  }

  /// Identifiant de l'equipement correspondant au [nom] donne pour ce profil.
  String? idDuProfil(Profil profil, String nom) {
    for (final ({String id, String nom}) e in _lot(profil.code)) {
      if (e.nom == nom) return e.id;
    }
    return null;
  }

  /// Variante role de [nomDuProfil], pour les appels qui ne portent qu'un
  /// role CDC.
  String? nomDu(String role, String id) {
    final Profil? profil = profilDuRole(role);
    return profil == null ? null : nomDuProfil(profil, id);
  }

  List<({String id, String nom})> _lot(String code) =>
      _equipements[code] ?? const <({String id, String nom})>[];

  /// Identifiant de l'appareil courant, inscrit comme `source_device`.
  void declarerAppareil(String id) => _appareil = id;

  /// Identifiant de la passerelle courante, inscrit comme `gateway_id` (§12).
  void declarerPasserelle(String id) => _passerelle = id;

  /// Versions lues dans `meta` (§23).
  String? meta(String cle) => _meta[cle];

  /// Ecrit une valeur dans `meta`.
  Future<void> majMeta(String cle, String valeur) async {
    _meta[cle] = valeur;
    _ecrire(
      (Database db) => db.insert(
        'meta',
        <String, Object?>{'cle': cle, 'valeur': valeur},
        conflictAlgorithm: ConflictAlgorithm.replace,
      ),
    );
    await attendreEcritures();
  }

  // ------------------------------------------------------------- affectation

  /// Valeur fournie par le serveur (`destination`, `dumping_area`, …).
  ///
  /// `null` tant que le serveur n'a rien renvoye : l'ecran affiche alors
  /// « en attente » plutot qu'un point choisi ici.
  String? affectation(String cle) => _affectation[cle]?.valeur;

  /// Horodatage de validation de [cle], affiche en badge par l'ecran DT.
  String? horodatageAffectation(String cle) =>
      _affectation[cle]?.horodatage;

  /// Affectation courante, pour les tests et le journal.
  Map<String, ({String valeur, String? horodatage})> get toutesAffectations =>
      Map<String, ({String valeur, String? horodatage})>.unmodifiable(
        _affectation,
      );

  /// Le serveur a choisi **et valide** ces valeurs : remplacement complet.
  ///
  /// Seule porte d'ecriture de la table. L'interface n'y passe jamais :
  /// destination et dumping area sont decidees en amont, l'application ne
  /// fait que les relayer avec l'horodatage de la validation.
  Future<void> enregistrerAffectation(
    Map<String, String> champs, {
    String? horodatage,
  }) async {
    if (champs.isEmpty) return;
    _affectation
      ..clear()
      ..addEntries(
        champs.entries.map(
          (MapEntry<String, String> e) =>
              MapEntry<String, ({String valeur, String? horodatage})>(
            e.key,
            (valeur: e.value, horodatage: horodatage),
          ),
        ),
      );
    _ecrire((Database db) async {
      final Batch batch = db.batch();
      batch.rawDelete('DELETE FROM affectation');
      for (final MapEntry<String, String> e in champs.entries) {
        batch.insert(
          'affectation',
          <String, Object?>{
            'cle': e.key,
            'valeur': e.value,
            'source': 'SERVEUR',
            'horodatage': horodatage,
          },
        );
      }
      await batch.commit(noResult: true);
    });
    journaliser(
      'AFFECTATION '
      '${champs.entries.map((e) => '${e.key}=${e.value}').join(' ')}',
    );
    await attendreEcritures();
  }

  /// Une mesure GPS du device, posee en file (CDC §5, §12).
  ///
  /// Le serveur analyse les positions pour decider destination et dumping
  /// area : chaque mesure part donc comme tout autre evenement, avec son
  /// `event_id` (idempotence REQ-015). Cadence maitrisee cote service :
  /// le GPS n'ecrit pas plus vite que [intervalle].
  void evenementPosition(PositionTerrain position) {
    _evenement('GPS_UPDATE', <String, Object?>{
      'easting': position.easting,
      'northing': position.northing,
      'elevation': position.elevation,
      if (position.wgs84 != null) ...<String, Object?>{
        'lat': position.wgs84!.lat,
        'lng': position.wgs84!.lng,
      },
    });
  }

  /// Une position de la **perle** (godet), exprimee en coordonnees de bloc
  /// (`Xbloc`, `Ybloc`, `Zbloc`) — profil excavator (§2.3).
  ///
  /// C'est la meme origine GNSS que `GPS_UPDATE`, mais projetee dans le
  /// repere du bloc de travail. Cette position est envoyee au DT pendant la
  /// session de connexion ; elle alimente aussi l'accumulateur de moyenne.
  /// [dt] : le DT avec lequel la session est ouverte (ex. `TAB2-DT13`).
  void evenementPositionPerle({
    required int xbloc,
    required int ybloc,
    required int zbloc,
    required String dt,
  }) {
    _evenement('POSITION_PERLE', <String, Object?>{
      'xbloc': xbloc,
      'ybloc': ybloc,
      'zbloc': zbloc,
      'dt': dt,
    });
  }

  /// La **moyenne** des positions de la perle sur une session de connexion
  /// (`Xmoy`, `Ymoy`, `Zmoy`) — profil excavator (§2.3).
  ///
  /// C'est cette moyenne qui sert au serveur a definir la Destination et la
  /// Dumping Area. Elle est calculee en continu pendant la session, gelee et
  /// envoyee a la sortie de zone du DT ("decollage"), puis remise a zero.
  void evenementMoyennePerle({
    required int xmoy,
    required int ymoy,
    required int zmoy,
    required int nombre,
    required String dt,
  }) {
    _evenement('MOYENNE_PERLE', <String, Object?>{
      'xmoy': xmoy,
      'ymoy': ymoy,
      'zmoy': zmoy,
      'nombre': nombre,
      'dt': dt,
    });
  }

  /// Evenements encore a transmettre (etat PENDING).
  Future<List<Map<String, Object?>>> evenementsEnAttente() async {
    final Database? db = _db;
    if (db == null) return const <Map<String, Object?>>[];
    return db.query(
      'evenements',
      where: 'etat = ?',
      whereArgs: <Object?>['PENDING'],
      orderBy: 'rowid',
    );
  }

  /// Evenements reellement eligibles : PENDING **et** tentative echue (§14).
  ///
  /// C'est ce que lit le worker de synchronisation : un evenement repousse par
  /// un backoff n'apparait pas avant l'heure. Vide sans base — il n'y a alors
  /// rien de persiste a transmettre.
  Future<List<Map<String, Object?>>> aTransmettre({
    int limite = 20,
    DateTime? maintenant,
  }) async {
    final Database? db = _db;
    if (db == null) return const <Map<String, Object?>>[];
    final int instant = (maintenant ?? DateTime.now()).millisecondsSinceEpoch;
    return db.query(
      'evenements',
      where: "etat = 'PENDING' AND "
          '(prochaine_tentative IS NULL OR prochaine_tentative <= ?)',
      whereArgs: <Object?>[instant],
      orderBy: 'rowid',
      limit: limite,
    );
  }

  /// Un evenement suivi individuellement (rejeu, tests).
  Future<Map<String, Object?>?> evenement(String eventId) async {
    final Database? db = _db;
    if (db == null) return null;
    final rows = await db.query(
      'evenements',
      where: 'event_id = ?',
      whereArgs: <Object?>[eventId],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  /// Nombre d'evenements en attente : ce que l'ecran du DT affiche (§21).
  int get nombreEnAttente => _enAttente;

  /// Un evenement part vers le serveur (etat SENDING, compteur de tentatives).
  Future<void> marquerEnCours(String eventId) async {
    final Database? db = _db;
    if (db == null) return;
    await db.rawUpdate(
      "UPDATE evenements SET etat = 'SENDING', tentatives = tentatives + 1 "
      'WHERE event_id = ?',
      <Object?>[eventId],
    );
  }

  /// Accuse de reception serveur recu (etat SYNCED, CDC §14).
  Future<void> marquerSynchronise(String eventId) async {
    final Database? db = _db;
    if (db == null) return;
    await db.update(
      'evenements',
      <String, Object?>{'etat': 'SYNCED', 'prochaine_tentative': null},
      where: 'event_id = ?',
      whereArgs: <Object?>[eventId],
    );
    await _recalculerAttente(db);
  }

  /// Echec de transmission : retour en PENDING pour un nouvel essai (§14).
  ///
  /// [nouvelleTentative] fixe le prochain essai (backoff du §14) : laissee
  /// vide, l'evenement est de nouveau immediatement eligibilable.
  Future<void> remettreEnAttente(
    String eventId, {
    DateTime? nouvelleTentative,
  }) async {
    final Database? db = _db;
    if (db == null) return;
    await db.update(
      'evenements',
      <String, Object?>{
        'etat': 'PENDING',
        'prochaine_tentative': nouvelleTentative?.millisecondsSinceEpoch,
      },
      where: 'event_id = ?',
      whereArgs: <Object?>[eventId],
    );
    await _recalculerAttente(db);
  }

  /// Recompte les evenements PENDING et met [nombreEnAttente] a jour.
  ///
  /// Appele apres CHAQUE transition d'etat (SYNCED, retour en PENDING) et
  /// desormais A L'OUVERTURE de la base. Sans ce dernier appel, le compteur
  /// repartait a 0 au redemarrage alors que des evenements attendaient
  /// encore : la supervision affichait un chiffre inferieur a la realite.
  Future<void> _recalculerAttente(Database db) async {
    _enAttente = Sqflite.firstIntValue(
          await db.rawQuery(
            'SELECT COUNT(*) FROM evenements WHERE etat = ?',
            <Object?>['PENDING'],
          ),
        ) ??
        _enAttente;
  }

  // --------------------------------------------------------------- ecritures

  /// Evenement BLE recu d'un TAB 3, stocké par TAB 2 (CDC §10/§11/§17).
  ///
  /// Idempotence locale (REQ-015) : un event_id déjà connu n'est pas
  /// re-stocké — le remettrait deux fois dans la file de synchro.
  void evenementRecu(Map<String, Object?> evenement) {
    final String eventId = '${evenement['event_id'] ?? ''}';
    if (eventId.isEmpty || _eventIdsConnus.contains(eventId)) {
      _journalBle.insert(0, 'DUPLICAT ignoré: $eventId');
      return;
    }
    _eventIdsConnus.add(eventId);
    _evenement('BLE_RELAY', evenement);
    _journalBle.insert(0, 'BLE_RELAY $eventId de ${evenement['source_device']}');
  }

  /// Event IDs déjà traités localement (idempotence CDC §17).
  final Set<String> _eventIdsConnus = <String>{};

  /// Journal technique BLE (CDC §22) : connexions, RSSI, doublons.
  final List<String> _journalBle = <String>[];

  /// Journal technique BLE lisible par l'UI (CDC §22).
  List<String> get journalBle => List<String>.unmodifiable(_journalBle);

  bool _refuser(String motif) {
    refusEnCours = motif;
    return false;
  }

  /// Ecrit une ligne dans le journal technique (CDC §22).
  ///
  /// Sert aux ecritures metier comme aux etapes de la synchronisation : ce
  /// journal est la preuve de ce que l'application a reellement fait.
  void journaliser(String requete) {
    final String horodatage = DateTime.now().toIso8601String();
    journal.insert(0, '${horodatage.substring(11, 19)}  $requete');
    _ecrire(
      (Database db) => db.insert(
        'journal',
        <String, Object?>{'horodatage': horodatage, 'requete': requete},
      ),
    );
  }

  bool _accepter(String requete) {
    refusEnCours = null;
    journaliser(requete);
    return true;
  }

  /// Ajoute une ligne au bloc donne, en tete du tableau.
  ///
  /// Verifie que le numero du DT appartient bien a la categorie choisie : la
  /// coherence type/numero est une regle de la base, pas de l'interface.
  /// Contenu reseau d'une ligne : exactement ce que le formulaire a saisi.
  ///
  /// Un seul endroit decrit les champs, utilise par [ajouterLigne] (une
  /// ligne, LINE_ADD) et par [envoyer] (le blast entier, BLAST_SEND) : les
  /// deux ne peuvent pas diverger, et rien ne reste sur le poste.
  static Map<String, Object?> _contenuLigne(LigneBlast ligne) =>
      <String, Object?>{
        'time': ligne.time,
        'dt': ligne.dt,
        'id_dt': ligne.idDt,
        'has_picture': ligne.hasPicture,
        if (ligne.photo != null) 'photo': base64Encode(ligne.photo!),
        'comment': ligne.comment,
      };

  bool ajouterLigne(BlocTravail bloc, LigneBlast ligne) {
    final Blast? blast = _blastDe(bloc);
    if (blast == null) return _refuser('Bloc inconnu');
    // v6 : le verrou porte sur la paire (blast, bloc). Verrouiller le bloc 8
    // n'empêche pas d'ecrire dans le bloc 6 du meme blast.
    if (bloc.verrouille) {
      return _refuser(
        'Bloc ${bloc.numero} du blast ${blast.numero} verrouille : '
        'aucune ligne acceptee',
      );
    }
    final TypeDT? type = typeDT(ligne.dt);
    if (type == null) return _refuser('Categorie de DT inconnue : ${ligne.dt}');
    if (!type.contient(ligne.idDt)) {
      return _refuser(
        'Le DT n\'${ligne.idDt} n\'existe pas en categorie ${ligne.dt} '
        '(lot : ${type.ids.join(', ')})',
      );
    }
    bloc.lignes.insert(0, ligne);
    _ecrire((Database db) async {
      final int? blocId = await _idDuBloc(db, blast.numero, bloc.numero);
      if (blocId == null) return;
      await db.insert('lignes', _ligneValeurs(blocId, ligne));
    });
    // Tout ce que le formulaire a capte part avec l'evenement : heure,
    // famille, numero, drapeau photo, octets et commentaire. La photo est
    // encodee en base64 pour tenir dans le payload JSON. Aucun champ du
    // formulaire ne reste sur le poste (« toutes les donnees partent »).
    _evenement('LINE_ADD', <String, Object?>{
      'blast': blast.numero,
      'bloc': bloc.numero,
      ..._contenuLigne(ligne),
    });
    return _accepter(
      'INSERT lignes (blast ${blast.numero}, bloc ${bloc.numero}, '
      'DT ${ligne.dt} n${ligne.idDt})',
    );
  }

  /// Verrouillage d'un bloc (paire blast/bloc, v6) : ce bloc est ferme, les
  /// autres du meme blast restent ouverts tant qu'on ne les verrouille pas.
  bool verrouiller(BlocTravail bloc) {
    final Blast? blast = _blastDe(bloc);
    if (blast == null) return _refuser('Bloc inconnu');
    if (bloc.verrouille) {
      return _refuser(
        'Bloc ${bloc.numero} du blast ${blast.numero} deja verrouille',
      );
    }
    bloc.verrouille = true;
    _ecrire(
      (Database db) => db.update(
        'blocs',
        <String, Object?>{'verrouille': 1},
        where: 'blast = ? AND numero = ?',
        whereArgs: <Object?>[blast.numero, bloc.numero],
      ),
    );
    _evenement('BLAST_LOCK', <String, Object?>{
      'blast': blast.numero,
      'bloc': bloc.numero,
      'lignes': bloc.nombreLignes,
    });
    return _accepter(
      'UPDATE blocs SET verrouille = 1 WHERE blast = ${blast.numero} '
      'AND numero = ${bloc.numero} (${bloc.nombreLignes} ligne(s))',
    );
  }

  /// Reouverture d'un bloc verrouille : la saisie reprend dans CE bloc, les
  /// autres blocs verrouilles ne sont pas touches.
  bool deverrouiller(BlocTravail bloc) {
    final Blast? blast = _blastDe(bloc);
    if (blast == null) return _refuser('Bloc inconnu');
    if (!bloc.verrouille) {
      return _refuser(
        'Bloc ${bloc.numero} du blast ${blast.numero} n\'est pas verrouille',
      );
    }
    bloc.verrouille = false;
    // Les donnees redeviennent modifiables : ce qui a deja parte sur le
    // reseau n'est plus a jour, on le signale plutot que de laisser croire
    // l'inverse. Le statut « envoye » reste porte par le blast entier.
    blast.envoye = false;
    _ecrire(
      (Database db) async {
        await db.update(
          'blocs',
          <String, Object?>{'verrouille': 0},
          where: 'blast = ? AND numero = ?',
          whereArgs: <Object?>[blast.numero, bloc.numero],
        );
        await db.update(
          'blasts',
          <String, Object?>{'envoye': 0},
          where: 'numero = ?',
          whereArgs: <Object?>[blast.numero],
        );
      },
    );
    _evenement('BLAST_UNLOCK', <String, Object?>{
      'blast': blast.numero,
      'bloc': bloc.numero,
    });
    return _accepter(
      'UPDATE blocs SET verrouille = 0, blasts SET envoye = 0 '
      'WHERE blast = ${blast.numero} AND numero = ${bloc.numero}',
    );
  }

  /// Transmet les donnees sauvegardees d'un blast au point d'acces.
  ///
  /// Le perimetre depend du mode courant ([envoiMode], cle `meta.envoi_mode`) :
  /// - `blast` : snapshot **complet**, tous les blocs du blast verrouilles ;
  /// - `bloc` : le seul bloc [numeroBloc], qui doit etre verrouille ;
  /// - `verrouilles` : les seuls blocs verrouilles du blast (au moins un).
  ///
  /// Dans tous les cas, seules des donnees deja fermees partent : tant que le
  /// spotter peut encore ecrire dedans, ce ne sont pas des donnees
  /// sauvegardees. Le statut « envoye » reste porte par le blast entier.
  bool envoyer(Blast blast, {String? numeroBloc}) {
    final String mode = envoiMode;
    final List<BlocTravail> cibles;
    switch (mode) {
      case envoiModeBloc:
        final BlocTravail? bloc =
            numeroBloc == null ? null : blast.bloc(numeroBloc);
        if (bloc == null) {
          return _refuser(
            'Bloc ${numeroBloc ?? '(absent)'} introuvable '
            'dans le blast ${blast.numero}',
          );
        }
        if (!bloc.verrouille) {
          return _refuser(
            'Bloc ${bloc.numero} du blast ${blast.numero} non verrouille : '
            'verrouillez-le avant d\'envoyer',
          );
        }
        cibles = <BlocTravail>[bloc];
      case envoiModeVerrouilles:
        cibles = blast.blocs
            .where((BlocTravail b) => b.verrouille)
            .toList(growable: false);
        if (cibles.isEmpty) {
          return _refuser(
            'Aucun bloc verrouille dans le blast ${blast.numero} : '
            'verrouillez au moins un bloc avant d\'envoyer',
          );
        }
      default:
        if (!blast.verrouille) {
          return _refuser(
            'Blast ${blast.numero} non verrouille : '
            'verrouillez-le avant d\'envoyer',
          );
        }
        cibles = blast.blocs;
    }
    final int lignes = cibles.fold<int>(
      0,
      (int total, BlocTravail b) => total + b.nombreLignes,
    );
    if (lignes == 0) {
      return _refuser('Blast ${blast.numero} sans donnee : rien a envoyer');
    }
    if (blast.envoye) {
      return _refuser('Blast ${blast.numero} deja envoye');
    }
    blast.envoye = true;
    _ecrire(
      (Database db) => db.update(
        'blasts',
        <String, Object?>{'envoye': 1},
        where: 'numero = ?',
        whereArgs: <Object?>[blast.numero],
      ),
    );
    // Snapshot du perimetre choisi : le serveur recoit les lignes du mode,
    // photos comprises. C'est ce qui garantit « ne laisse rien » — y compris
    // pour les lignes de depart, qui n'ont jamais eu de LINE_ADD.
    _evenement('BLAST_SEND', <String, Object?>{
      'blast': blast.numero,
      'carte': blast.cartes.isNotEmpty ? blast.cartes.first : '',
      'mode': mode,
      'lignes': lignes,
      'blocs': cibles.length,
      if (mode == envoiModeBloc) 'bloc': numeroBloc,
      'donnees': <Map<String, Object?>>[
        for (final BlocTravail bloc in cibles)
          for (final LigneBlast ligne in bloc.lignes)
            <String, Object?>{'bloc': bloc.numero, ..._contenuLigne(ligne)},
      ],
    });
    return _accepter(
      'SEND blast ${blast.numero} mode $mode - $lignes ligne(s) '
      '(${cibles.length} bloc(s), '
      'carte ${blast.cartes.isNotEmpty ? blast.cartes.first : '-'})',
    );
  }

  Blast? _blastDe(BlocTravail bloc) {
    for (final blast in blasts) {
      if (identical(blast.bloc(bloc.numero), bloc)) return blast;
    }
    return null;
  }

  // ---------------------------------------------------------- reception serveur

  /// Alimente la base avec la liste des blasts venue du serveur.
  ///
  /// C'est le sens **serveur -> app** de la synchro : les listes des menus
  /// « Select blast » / « Select bloc » et les plans des cartes s'y remplis-
  /// sent. Regles de reception :
  /// - **upsert sur le numero** : un blast deja connu est mis a jour (blocs,
  ///   carte), jamais duplique ;
  /// - **les lignes et les verrous ne sont jamais touches** : ce que le
  ///   spotter a saisi hors ligne appartient au poste, le serveur ne les
  ///   porte pas ;
  /// - **idempotent** : rappeler avec la meme liste ne change rien et ne
  ///   journalise plus (comparaison d'empreinte, comme l'affectation) ;
  /// - un blast sans numero ou sans carte est ignore : il repassera a la
  ///   prochaine passe quand le serveur le completera.
  ///
  /// Rend le nombre de blasts reelslement ecrits (nouveaux, modifies, supprimes).
  int recevoirBlasts(List<BlastServeur> liste) {
    // La liste serveur fait foi pour la STRUCTURE (blasts, cartes/RL, blocs).
    // Ce qui appartient au poste n'est jamais touche : lignes saisies, photos,
    // verrous. Un blast ou un bloc qui porte des donnees locales est conserve
    // et signale comme orphelin au lieu d'etre supprime en silence.
    final Set<String> numerosServeur = <String>{
      for (final BlastServeur s in liste)
        if (s.numero.isNotEmpty) s.numero,
    };

    // Blast absent du serveur : purge UNIQUEMENT s'il ne contient aucune
    // donnee saisie (aucune ligne, aucun verrou).
    final List<String> numerosObsoletes = <String>[];
    final List<String> blastsConserves = <String>[];
    for (final Blast b in blasts) {
      if (numerosServeur.contains(b.numero)) continue;
      final bool conserve = b.blocs.any(
        (BlocTravail bloc) => bloc.verrouille || bloc.nombreLignes > 0,
      );
      if (conserve) {
        blastsConserves.add(b.numero);
      } else {
        numerosObsoletes.add(b.numero);
      }
    }
    // Log de diagnostic : la prochaine fois que l'utilisateur voit encore
    // 119/120/121 apres une synchro, on saura immediatement si le serveur
    // a envoye la nouvelle liste (et donc si la purge a bien eu lieu) ou
    // si le probleme est en amont (reseau, token, deploiement serveur).
    debugPrint(
      'recevoirBlasts: serveur=${liste.length} blast(s) '
      '[${liste.map((b) => b.numero).join(', ')}] '
      'locaux=${blasts.length} obsoletes=${numerosObsoletes.length} '
      '[${numerosObsoletes.join(', ')}]',
    );
    int ecrits = 0;
    if (numerosObsoletes.isNotEmpty) {
      for (final String numero in numerosObsoletes) {
        blasts.removeWhere((b) => b.numero == numero);
      }
      _ecrire((Database db) async {
        for (final String numero in numerosObsoletes) {
          await db.delete('blocs', where: 'blast = ?', whereArgs: <Object?>[numero]);
          await db.delete('blasts', where: 'numero = ?', whereArgs: <Object?>[numero]);
        }
      });
      journaliser(
        'PURGE blasts locaux absents du serveur : '
        '${numerosObsoletes.join(', ')}',
      );
      ecrits += numerosObsoletes.length;
    }
    if (blastsConserves.isNotEmpty) {
      journaliser(
        'BLASTS orphelins conserves (donnees locales) : '
        '${blastsConserves.join(', ')}',
      );
    }

    // URL des plans : on enregistre l'URL de CHAQUE carte du blast (une par
    // RL). `blast.plan` ne peut porter qu'une seule URL, celle de la premiere
    // carte ; sans cette table, changer de RL ne changerait pas le plan.
    for (final BlastServeur serveur in liste) {
      if (serveur.planUrl.isNotEmpty) {
        poserUrlPlan(serveur.carte, serveur.planUrl);
      }
      serveur.planUrlParCarte.forEach(poserUrlPlan);
    }

    for (final BlastServeur serveur in liste) {
      if (serveur.numero.isEmpty || serveur.carte.isEmpty) continue;
      final Blast? existant = parNumero(serveur.numero);
      if (existant != null) {
        // Cartes/RL : la liste serveur fait foi (remplacement, pas fusion).
        // Le plan local deja telecharge n'est jamais perdu.
        final List<String> cartesServeur = serveur.cartes.isNotEmpty
            ? serveur.cartes
            : <String>[serveur.carte];
        existant.cartes
          ..clear()
          ..addAll(cartesServeur);
        if (existant.plan.isEmpty || existant.plan.startsWith('http')) {
          existant.plan = _planDe(serveur);
        }
        // Blocs rattaches a leur carte (RL) quand le serveur les fournit ;
        // sinon repli sur la liste plate appliquee a la premiere carte.
        final Map<String, List<String>> parCarte =
            serveur.blocsParCarte.isNotEmpty
                ? serveur.blocsParCarte
                : <String, List<String>>{
                    cartesServeur.first: serveur.blocs,
                  };
        // Ensemble des cles (numero, carte) attendues par le serveur.
        final Set<String> clesServeur = <String>{};
        for (final MapEntry<String, List<String>> e in parCarte.entries) {
          for (final String numeroBloc in e.value) {
            if (numeroBloc.isEmpty) continue;
            clesServeur.add('$numeroBloc\u0000${e.key}');
            // Cle (blast, bloc, carte) : le meme numero de bloc peut exister
            // sur plusieurs RL du meme blast, ce sont deux blocs distincts.
            if (!existant.aBloc(numeroBloc, e.key)) {
              existant.blocs.add(
                BlocTravail(numero: numeroBloc, carte: e.key),
              );
            }
          }
        }
        // Blocs locaux absents du serveur : suppression seulement s'ils ne
        // portent ni ligne saisie ni verrou (donnees du poste intouchables).
        final List<BlocTravail> blocsRetires = <BlocTravail>[];
        for (final BlocTravail bloc in existant.blocs) {
          final String cle = '${bloc.numero}\u0000${bloc.carte}';
          if (clesServeur.contains(cle)) continue;
          if (bloc.verrouille || bloc.nombreLignes > 0) continue;
          blocsRetires.add(bloc);
        }
        if (blocsRetires.isNotEmpty) {
          existant.blocs.removeWhere(blocsRetires.contains);
          _ecrire((Database db) async {
            for (final BlocTravail bloc in blocsRetires) {
              await db.delete(
                'blocs',
                where: 'blast = ? AND numero = ? AND carte = ?',
                whereArgs: <Object?>[
                  serveur.numero,
                  bloc.numero,
                  bloc.carte,
                ],
              );
            }
          });
          journaliser(
            'RETRAIT blocs absents du serveur (blast ${serveur.numero}) : '
            '${blocsRetires.map((b) => '${b.numero}@${b.carte}').join(', ')}',
          );
        }
        _ecrire((Database db) async {
          await db.update(
            'blasts',
            <String, Object?>{
              'carte': existant.cartes.join(','),
              'plan': existant.plan,
            },
            where: 'numero = ?',
            whereArgs: <Object?>[serveur.numero],
          );
          for (final BlocTravail bloc in existant.blocs) {
            await _ecrireBlocSiAbsent(
              db,
              serveur.numero,
              bloc.numero,
              bloc.carte,
            );
          }
        });
        journaliser(
          'UPDATE blasts numero = ${serveur.numero} (serveur, '
          '${existant.blocs.length} bloc(s), carte ${serveur.carte})',
        );
      } else {
        // Nouveau blast : cree avec ses cartes et ses blocs.



        final List<String> cartesServeur = serveur.cartes.isNotEmpty
            ? serveur.cartes
            : <String>[serveur.carte];
        final Map<String, List<String>> parCarte =
            serveur.blocsParCarte.isNotEmpty
                ? serveur.blocsParCarte
                : <String, List<String>>{
                    cartesServeur.first: serveur.blocs,
                  };
        final List<BlocTravail> blocsInitiaux = <BlocTravail>[];
        for (final MapEntry<String, List<String>> e in parCarte.entries) {
          for (final String numeroBloc in e.value) {
            if (numeroBloc.isEmpty) continue;
            if (blocsInitiaux.any((BlocTravail b) =>
                b.numero == numeroBloc && b.carte == e.key)) {
              continue;
            }
            blocsInitiaux.add(
              BlocTravail(numero: numeroBloc, carte: e.key),
            );
          }
        }
        final Blast blast = Blast(
          numero: serveur.numero,
          cartes: List<String>.from(cartesServeur),
          plan: _planDe(serveur),
          blocs: blocsInitiaux,
        );
        blasts.add(blast);
        _ecrire((Database db) async {
          await db.insert('blasts', <String, Object?>{
            'numero': blast.numero,
            'carte': blast.cartes.join(','),
            'plan': blast.plan,
            'envoye': 0,
          });
          for (final BlocTravail bloc in blast.blocs) {
            await _ecrireBlocSiAbsent(
              db,
              blast.numero,
              bloc.numero,
              bloc.carte,
            );
          }
        });
        journaliser(
          'INSERT blasts numero = ${serveur.numero} (serveur, '
          '${blast.blocs.length} bloc(s), carte ${serveur.carte})',
        );
      }
      // Le libelle de la carte alimente la table `cartes` si le serveur en
      // fournit un : la legende du plan ne depend plus du seed.
      if (serveur.libelleCarte.isNotEmpty &&
          libelleCarte(serveur.carte) != serveur.libelleCarte) {
        _carteLabel[serveur.carte] = serveur.libelleCarte;
        _ecrire(
          (Database db) => db.insert(
            'cartes',
            <String, Object?>{
              'code': serveur.carte,
              'libelle': serveur.libelleCarte,
            },
            conflictAlgorithm: ConflictAlgorithm.replace,
          ),
        );
      }
      ecrits++;
    }
    return ecrits;
  }

  /// Chemin du plan pour un blast recu : l'URL serveur tant que le JPG
  /// n'est pas telecharge, le chemin local ensuite (pose par le worker).
  String _planDe(BlastServeur serveur) =>
      _plansLocaux[serveur.carte] ?? serveur.planUrl;

  /// Chemins locaux des plans deja telecharges, par code de carte.
  final Map<String, String> _plansLocaux = <String, String>{};

  /// URL serveur de chaque carte, lue a la reception des blasts.
  ///
  /// Un blast couvre N cartes (une par RL) : `blast.plan` ne peut en porter
  /// qu'une. Cette table est la seule source pour afficher le plan du RL
  /// selectionne tant qu'il n'est pas encore telecharge en local.
  final Map<String, String> _planUrls = <String, String>{};

  /// Chemin du plan local pour une carte donnee, si telecharge.
  String? planDe(String carte) => _plansLocaux[carte];

  /// Plan d'une carte, dans l'ordre de preference :
  /// 1. fichier local deja telecharge ;
  /// 2. URL serveur de CETTE carte (pas celle de la premiere du blast) ;
  /// 3. URL Apps Script construite a la volee `?action=plan&carte=<code>`.
  ///
  /// Le repli 3 est indispensable : tant que la synchro n'a pas tourne depuis
  /// le deploiement serveur qui renvoie `blocs_par_carte[].plan_url`, la table
  /// [_planUrls] est vide et `planCourant` retomberait sur `blast.plan`, qui
  /// ne porte QUE la premiere carte du blast (bug RL 262.5 -> plan 260).
  ///
  /// Rend `null` seulement si le code de carte est vide.
  String? planPourCarte(String carte) {
    if (carte.isEmpty) return null;
    final String? local = _plansLocaux[carte];
    if (local != null && local.isNotEmpty) return local;
    final String? url = _planUrls[carte];
    if (url != null && url.isNotEmpty) return url;
    // Repli : URL du plan de CETTE carte, derivee du code seul. Le serveur
    // resout le fichier Drive par son nom de base, donc le code suffit.
    final String base = _baseServeur;
    if (base.isEmpty) return null;
    final String sep = base.contains('?') ? '&' : '?';
    return '$base${sep}action=plan&carte=${Uri.encodeComponent(carte)}';
  }

  /// Racine de l'URL de la Web App (sans `?action=...`), posee a la
  /// configuration des parametres. Sert au repli de [planPourCarte].
  String _baseServeur = '';

  /// Enregistre la racine de la Web App pour construire les URL de plans
  /// a la volee. Appele a la configuration des parametres serveur.
  void poserBaseServeur(String url) {
    _baseServeur = url.trim();
  }

  /// URL serveur connue pour une carte (null si jamais recue).
  String? urlPlanDe(String carte) => _planUrls[carte];

  /// Enregistre l'URL serveur d'une carte (reception des blasts).
  void poserUrlPlan(String carte, String url) {
    if (carte.isEmpty || url.isEmpty) return;
    _planUrls[carte] = url;
  }

  /// Pose le chemin local d'un plan telecharge : les blasts de cette carte
  /// lisent desormais le fichier au lieu de l'URL serveur.
  /// Pose le chemin local d'un plan telecharge, POUR CETTE CARTE seulement.
  ///
  /// `blast.plan` n'est PAS mis a jour : un blast multi-RL a plusieurs plans
  /// et cette colonne ne peut en porter qu'un. La source de verite est
  /// [_plansLocaux], indexee par code de carte.
  void poserPlanLocal(String carte, String cheminFichier) {
    if (carte.isEmpty || cheminFichier.isEmpty) return;
    _plansLocaux[carte] = cheminFichier;
  }

  /// Charge au demarrage les plans deja telecharges dans le dossier
  /// documents de l'application (`plan_<code>.<ext>`).
  ///
  /// Sans ce scan, [_plansLocaux] serait vide apres un redemarrage et le
  /// client retomberait sur les URL serveur a chaque ouverture de carte.
  Future<void> chargerPlansLocaux() async {
    // Racine de la Web App : relue du meta avant tout, elle sert au repli de
    // `planPourCarte` quand l'URL d'une carte n'a pas encore ete recue.
    final String apiBase = meta('api_base') ?? '';
    if (apiBase.isNotEmpty) poserBaseServeur(apiBase);
    try {
      final Directory dossier = await getApplicationDocumentsDirectory();
      if (!await dossier.exists()) return;
      final RegExp motif = RegExp(r'^plan_(.+)\.(jpg|jpeg|png|gif)$');
      await for (final FileSystemEntity entite in dossier.list()) {
        if (entite is! File) continue;
        final String nom = entite.uri.pathSegments.last;
        final RegExpMatch? m = motif.firstMatch(nom);
        if (m == null) continue;
        _plansLocaux[m.group(1)!] = entite.path;
      }
    } catch (e) {
      debugPrint('Chargement des plans locaux impossible : $e');
    }
  }

  /// Ecrit un bloc s'il n'existe pas encore sur le disque : l'upsert memoire
  /// est reflechi sur le fichier sans jamais ecraser un bloc existant (ni
  /// son verrou, ni ses lignes).
  Future<void> _ecrireBlocSiAbsent(
    Database db,
    String numeroBlast,
    String numeroBloc,
    String carte,
  ) async {
    if (await _idDuBloc(db, numeroBlast, numeroBloc, carte: carte) != null) {
      return;
    }
    await db.insert(
      'blocs',
      <String, Object?>{
        'blast': numeroBlast,
        'numero': numeroBloc,
        'carte': carte,
        'verrouille': 0,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  // ------------------------------------------------------------------ seeds

  // ------------------------------------------------- notifications serveur

  /// Curseur de lecture des notifications (dernier id recu), dans `meta` :
  /// une reprise apres coupure ne repart jamais de zero et ne rejoue donc
  /// pas les vieux messages.
  int get derniereIdNotification => int.tryParse(meta('derniere_id_notif') ?? '') ?? 0;

  /// Notifications recues du serveur, les plus recentes d'abord. Filtrees par
  /// [codeProfil] : une notification a `profil = ''` s'adresse a tout le
  /// monde, une notification ciblee ne sort que pour son profil.
  List<NotificationServeur> notifications(String codeProfil) =>
      _notifications
          .where((NotificationServeur n) =>
              n.profil.isEmpty || n.profil == codeProfil)
          .toList(growable: false);

  final List<NotificationServeur> _notifications = <NotificationServeur>[];

  /// Ecrit les notifications servies par le serveur et rend le nombre de
  /// nouveautes reelslement posees. Idempotent (cle = id serveur) : un
  /// rejoue apres coupure ne duplique rien et ne remonte pas le curseur
  /// au-dela de ce qui est reelslement en base.
  int recevoirNotifications(List<NotificationServeur> liste) {
    int ecrits = 0;
    for (final NotificationServeur n in liste) {
      if (n.id <= derniereIdNotification) continue;
      if (_notifications.any((NotificationServeur a) => a.id == n.id)) continue;
      _notifications.add(n);
      ecrits++;
      _ecrire(
        (Database db) => db.insert(
          'notifications',
          <String, Object?>{
            'id': n.id,
            'profil': n.profil,
            'message': n.message,
            'horodatage': n.horodatage,
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        ),
      );
    }
    if (ecrits > 0) {
      final int nouveau = liste.fold<int>(
        derniereIdNotification,
        (int max, NotificationServeur n) => n.id > max ? n.id : max,
      );
      _ecrire(
        (Database db) => db.insert(
          'meta',
          <String, Object?>{'cle': 'derniere_id_notif', 'valeur': '$nouveau'},
          conflictAlgorithm: ConflictAlgorithm.replace,
        ),
      );
      // La memoire doit refletter le disque sans attendre la relecture.
      _meta['derniere_id_notif'] = '$nouveau';
    }
    return ecrits;
  }

  /// Relit la table `notifications` du disque (appelle par [_recharger] au
  /// demarrage : les messages recus hier sont encore la aujourd'hui).
  Future<void> _rechargerNotifications(Database db) async {
    _notifications
      ..clear()
      ..addAll(
        (await db.query('notifications', orderBy: 'id'))
            .map((row) => NotificationServeur(
                  id: (row['id']! as num).toInt(),
                  profil: (row['profil'] as String?) ?? '',
                  message: row['message']! as String,
                  horodatage: (row['horodatage'] as String?) ?? '',
                ))
            .toList(),
      );
  }

  /// Familles de DT, chacune avec son lot de numeros.
  ///
  /// Les identifiants sont non redondants sur tout le parc : le numero 01 n'a
  /// de place que dans la famille 1500. Le troisieme DT de chaque famille est
  /// celui que l'image source coupe en bas.
  ///
  /// Vide en production : les libelles viennent du serveur (snapshot
  /// `cartes.libelle` synchronise dans [_carteLabel]) et `libelleCarte(code)`
  /// les lit prioritairement. Les tests utilisent [blastsDemo] pour disposer
  /// de jeux de libelles/positions sans polluer la base reelle.
  static Map<String, String> _carteLabelsInit() => <String, String>{};

  /// Points geographiques, en WGS84.
  ///
  /// Vide en production : les positions viennent du serveur (snapshot
  /// `affectation` + referentiels) et atterrissent dans [_positions].
  /// Les tests utilisent [blastsDemo] pour disposer de coordonnees stables.
  static Map<String, ({double lat, double lng})> _positionsInit() =>
      <String, ({double lat, double lng})>{};

  /// Ligne SQL d'un profil reçue via le référentiel serveur.
  static Map<String, Object?> _profilValeurs(Profil profil) =>
      <String, Object?>{
        'code': profil.code,
        'libelle': profil.libelle,
        'titre': profil.titre,
        'role_cdc': profil.roleCdc,
        'icone': profil.icone,
        'ordre': profil.ordre,
        'actif': profil.actif ? 1 : 0,
      };

  static Profil _profilLigne(Map<String, Object?> ligne) => Profil(
        code: ligne['code']! as String,
        libelle: ligne['libelle']! as String,
        titre: (ligne['titre'] as String?) ?? '',
        roleCdc: ligne['role_cdc']! as String,
        icone: (ligne['icone'] as String?) ?? '',
        ordre: (ligne['ordre'] as num?)?.toInt() ?? 0,
        actif: ((ligne['actif'] as num?)?.toInt() ?? 1) != 0,
      );


  /// Blasts de demonstration, **jamais semes en production** : le vrai
  /// travail du spotter arrive du serveur. Les tests les injectent avec
  /// `BaseLocale(blasts: BaseLocale.blastsDemo())` pour disposer des memes
  /// 119/120/121 (et de leurs lignes de depart) sans polluer les tablettes.
  @visibleForTesting
  static List<Blast> blastsDemo() => <Blast>[
        Blast.legacy(
          numero: '119',
          carte: 'A1',
          plan: 'assets/images/cartes/plans/119_A1.jpg',
          blocs: <BlocTravail>[
            BlocTravail(
              numero: '6',
              carte: 'A1',
              lignes: <LigneBlast>[
                LigneBlast(
                  time: '08h24',
                  dt: '1500',
                  idDt: '01',
                  hasPicture: true,
                  comment: 'Comment',
                ),
                LigneBlast(
                  time: '08h41',
                  dt: '1500',
                  idDt: '08',
                  comment: 'Fissure ouest',
                ),
              ],
            ),
            BlocTravail(numero: '7', carte: 'A1'),
            BlocTravail(numero: '8', carte: 'A1'),
          ],
        ),
        Blast.legacy(
          numero: '120',
          carte: 'B2',
          plan: 'assets/images/cartes/plans/120_B2.jpg',
          blocs: <BlocTravail>[
            BlocTravail(
              numero: '3',
              carte: 'B2',
              lignes: <LigneBlast>[
                LigneBlast(
                  time: '10h05',
                  dt: '785',
                  idDt: '09',
                  hasPicture: true,
                  comment: 'Roche dure',
                ),
                LigneBlast(
                  time: '10h41',
                  dt: '2500',
                  idDt: '20',
                  comment: 'Fissure nord',
                ),
              ],
            ),
            BlocTravail(numero: '4', carte: 'B2'),
            BlocTravail(numero: '5', carte: 'B2'),
          ],
        ),
        Blast.legacy(
          numero: '121',
          carte: 'D1',
          plan: 'assets/images/cartes/plans/121_D1.jpg',
          blocs: <BlocTravail>[
            BlocTravail(numero: '1', carte: 'D1'),
            BlocTravail(numero: '2', carte: 'D1'),
          ],
        ),
      ];
}

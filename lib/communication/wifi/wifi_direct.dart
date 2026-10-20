import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Point d'acces Wi-Fi automatique cote excavatrice, via Wi-Fi Direct natif.
///
/// **Pourquoi un canal natif.** Le hotspot Wi-Fi n'est pas activable en Dart :
/// `WifiManager.startLocalOnlyHotspot()` est reserve aux applications systeme
/// depuis Android 13. La seule API publique qui permette a l'excavatrice de
/// devenir point d'acces sans manipulation manuelle est `WifiP2pManager`
/// (Wi-Fi Direct), qui vit en Kotlin — d'ou ce `MethodChannel`
/// (`ore_tracking/wifi_direct`, voir `MainActivity.kt` et
/// `WifiDirectManager.kt`).
///
/// **Hors Android, tout est no-op** : la classe rend `false` sans rien faire,
/// ce qui laisse l'application tourner sur Windows/web (tests, diagnostic).
///
/// Ce service ne remplace pas le serveur TCP applicatif : il cree le **reseau**
/// (Wi-Fi Direct impose une interface, souvent 192.168.49.x) sur lequel
/// `TransportTcpWifi.heberger()` écoute ensuite. Les DT s'y connectent avec
/// l'adresse du Group Owner que [etat] expose.
class WifiDirect {
  WifiDirect._();

  static const MethodChannel _canal = MethodChannel('ore_tracking/wifi_direct');

  /// Mot de passe fixe du point d'acces cote excavatrice.
  ///
  /// Doit rester **le meme a chaque demarrage** : c'est ce qui permet a un DT
  /// deja enrole de se reconnecter sans jamais ressaisir d'identifiants. La
  /// valeur est dupliquee dans `HotspotManager.MOT_DE_PASSE_DEFAUT` (cote
  /// Kotlin, Android 13+ ne peut fixer que ce qui lui est transmis).
  static const String _motDePasseDefaut = 'oretracking';

  /// Mot de passe annonce aux clients (visible sur l'ecran excavator).
  static String get motDePassePointAcces => _motDePasseDefaut;

  /// Vrai sur Android : seule plateforme ou le canal natif existe.
  static bool get _estAndroid => !kIsWeb && Platform.isAndroid;

  /// Cree le groupe Wi-Fi Direct et force l'excavatrice en Group Owner.
  ///
  /// [nom] : nom du groupe annonce (prefixe `ORE-EXC`), pour que les DT le
  /// reconnaissent. Rend `true` si le groupe est forme. Ne leve jamais : un
  /// echec (permission refusee, materiel absent) rend `false`, l'appelant
  /// journalise et continue.
  static Future<bool> demarrer({String nom = 'ORE-EXC-001'}) async {
    final DemarrageReseau? r = await demarrerDetaille(nom: nom);
    return r?.ok ?? false;
  }

  /// Demarre le point d'acces et rend le reseau **reellement** cree.
  ///
  /// Android ne conserve pas le nom demande : il suffixe le SSID pour eviter
  /// les collisions (`ORE-EXC-001-a1b2`) et choisit lui-meme le mot de passe.
  /// Ce sont ces valeurs-la que les clients doivent employer — un client qui
  /// cherche `ORE-EXC-001` au caractere pres ne trouverait rien.
  ///
  /// Rend `null` hors Android ou si le canal natif estabsent.
  static Future<DemarrageReseau?> demarrerDetaille({
    String nom = 'ORE-EXC-001',
    String motDePasse = _motDePasseDefaut,
  }) async {
    if (!_estAndroid) return null;
    try {
      final Map<Object?, Object?>? reponse =
          await _canal.invokeMethod<Map<Object?, Object?>>(
        'demarrer',
        <String, Object?>{'nom': nom, 'motDePasse': motDePasse},
      );
      if (reponse == null) return null;
      return DemarrageReseau(
        ok: reponse['ok'] == true,
        erreur: reponse['erreur']?.toString(),
        ssid: reponse['ssid']?.toString(),
        motDePasse: reponse['motDePasse']?.toString(),
        type: reponse['type']?.toString() ?? 'inconnu',
      );
    } on PlatformException catch (e) {
      return DemarrageReseau(ok: false, erreur: e.message, type: 'erreur');
    } on MissingPluginException {
      // Canal absent (plugin non compile) : on ne bloque pas l'app.
      return null;
    }
  }

  /// Ferme le groupe : l'excavatrice cesse d'etre point d'acces.
  static Future<bool> arreter() async {
    if (!_estAndroid) return false;
    try {
      final Map<Object?, Object?>? reponse =
          await _canal.invokeMethod<Map<Object?, Object?>>('arreter');
      return reponse?['ok'] == true;
    } catch (_) {
      return false;
    }
  }

  /// Etat courant du lien Wi-Fi Direct.
  ///
  /// Cles rendues : `disponible` (pile presente), `groupOwner` (l'appareil
  /// est-il le point d'acces), `groupeForme`, `adresseGroupOwner` (IP a
  /// annoncer aux DT), `adresseLocale`.
  static Future<Map<String, Object?>> etat() async {
    if (!_estAndroid) return const <String, Object?>{};
    try {
      final Map<Object?, Object?>? reponse =
          await _canal.invokeMethod<Map<Object?, Object?>>('etat');
      if (reponse == null) return const <String, Object?>{};
      return reponse.map<String, Object?>(
        (Object? cle, Object? valeur) => MapEntry<String, Object?>('$cle', valeur),
      );
    } catch (_) {
      return const <String, Object?>{};
    }
  }

  /// Decouvre les groupes Wi-Fi Direct a portee (role client : DT, spotter).
  ///
  /// Rend la liste des pairs vus, chacun sous la forme
  /// `{nom, adresse, statut}`. L'excavatrice porte un nom commencant par
  /// `ORE-EXC`. Liste vide hors Android ou si rien n'est a portee.
  static Future<List<Map<String, String>>> decouvrir() async {
    if (!_estAndroid) return const <Map<String, String>>[];
    try {
      final Map<Object?, Object?>? reponse =
          await _canal.invokeMethod<Map<Object?, Object?>>('decouvrir');
      final Object? pairs = reponse?['pairs'];
      if (pairs is! List) return const <Map<String, String>>[];
      return <Map<String, String>>[
        for (final Object? item in pairs)
          if (item is Map)
            <String, String>{
              for (final MapEntry<Object?, Object?> e in item.entries)
                '${e.key}': '${e.value}',
            },
      ];
    } catch (_) {
      return const <Map<String, String>>[];
    }
  }

  /// Se connecte au groupe [nom] (celui de l'excavatrice).
  ///
  /// Le groupe doit avoir ete vu au prealable par [decouvrir] : Wi-Fi Direct
  /// ne se connecte qu'a un pair deja decouvert. Rend `true` si la demande
  /// de connexion a ete acceptee. Ne leve jamais.
  static Future<bool> connecter({String nom = 'ORE-EXC'}) async {
    if (!_estAndroid) return false;
    try {
      final Map<Object?, Object?>? reponse =
          await _canal.invokeMethod<Map<Object?, Object?>>(
        'connecter',
        <String, Object?>{'nom': nom},
      );
      return reponse?['ok'] == true;
    } catch (_) {
      return false;
    }
  }

  /// Oublie un groupe enregistre par le systeme (nettoyage).
  static Future<bool> oublier() async {
    if (!_estAndroid) return false;
    try {
      final Map<Object?, Object?>? reponse =
          await _canal.invokeMethod<Map<Object?, Object?>>('oublier');
      return reponse?['ok'] == true;
    } catch (_) {
      return false;
    }
  }

  /// Liste des DT connectes au groupe (supervision §21/§22).
  static Future<List<String>> clients() async {
    if (!_estAndroid) return const <String>[];
    try {
      final Map<Object?, Object?>? reponse =
          await _canal.invokeMethod<Map<Object?, Object?>>('clients');
      final Object? liste = reponse?['clients'];
      if (liste is List) return liste.map((Object? e) => '$e').toList();
      return const <String>[];
    } catch (_) {
      return const <String>[];
    }
  }
}

/// Resultat d'un demarrage de reseau local (hotspot ou Wi-Fi Direct).
///
/// [type] dit **quelle voie** a repondu : `hotspot` (voie normale), `wifi_direct`
/// (repli) ou `erreur`. [ssid] et [motDePasse] ne sont renseignes que par le
/// hotspot : c'est Android qui les choisit, l'application doit les employer
/// tels quels pour que les clients s'y connectent.
class DemarrageReseau {
  const DemarrageReseau({
    required this.ok,
    this.erreur,
    this.ssid,
    this.motDePasse,
    this.type = 'inconnu',
  });

  final bool ok;
  final String? erreur;
  final String? ssid;
  final String? motDePasse;
  final String type;

  @override
  String toString() => ok
      ? 'DemarrageReseau($type, ssid: ${ssid ?? '-'})'
      : 'DemarrageReseau(ECHEC $type : ${erreur ?? 'motif inconnu'})';
}

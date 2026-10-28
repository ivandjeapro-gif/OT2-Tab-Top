import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

/// Demande des permissions BLE **runtime** au premier lancement (Android 12+).
///
/// Le manifeste de l'application declare deja toutes les permissions BLE
/// (`BLUETOOTH_SCAN`, `BLUETOOTH_CONNECT`, `BLUETOOTH_ADVERTISE`,
/// `ACCESS_FINE_LOCATION`). Mais sur Android 12 (API 31) et au-dela, ce sont
/// des permissions **runtime** : declarees ne veut pas dire accordees. Sans
/// cette demande explicite, l'advertising du role peripherique (excavatrice)
/// et le scan du role central (DT) echouent **silencieusement** — la couche
/// croit demarrer, rien ne circule.
///
/// Le BLE est le seul moyen d'echange qui soit activable par l'application :
/// contrairement au hotspot Wi-Fi, `BLUETOOTH_ADVERTISE` n'est soumis a
/// aucun privilege systeme. C'est pourquoi on s'en occupe ici.
///
/// Sur les autres plateformes (Windows, web, iOS), il n'y a rien a demander :
/// l'appel est un no-op qui rend `true`.
class PermissionsBle {
  PermissionsBle._();

  /// Vrai sur Android : la seule plateforme ou la demande runtime s'applique
  /// (iOS a son propre modele de popup, gere par les plugins BLE eux-memes).
  static bool get _estAndroid => !kIsWeb && Platform.isAndroid;

  /// Demande les permissions BLE et rend `true` si tout ce qui est necessaire
  /// est accorde.
  ///
  /// Sur Android < 12, seules `ACCESS_FINE_LOCATION` (scan) et les
  /// anciennes permissions `BLUETOOTH`/`BLUETOOTH_ADMIN` comptent : elles
  /// sont accordees a l'installation, la demande est alors instantanee.
  /// Sur Android >= 12, ce sont les trois `BLUETOOTH_*` qui sont demandees.
  ///
  /// Ne leve jamais : un refus rend `false`, l'appelant decide de continuer
  /// (la couche BLE reste simplement inoperante jusqu'a la prochaine
  /// tentative).
  static Future<bool> demander() async {
    if (!_estAndroid) return true;
    try {
      // Un lot unique : Android presente une seule boite de dialogue pour
      // tout le groupe « Appareils à proximité » (API 31+).
      final Map<Permission, PermissionStatus> resultats =
          await <Permission>[
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.bluetoothAdvertise,
        Permission.locationWhenInUse,
      ].request();

      // Ce qui doit etre accorde pour que la couche fonctionne. On tolere
      // `locationWhenInUse` absent : sur Android >= 12 avec le drapeau
      // `neverForLocation`, le scan fonctionne sans localisation.
      final bool scan = resultats[Permission.bluetoothScan]?.isGranted ?? false;
      final bool connecter =
          resultats[Permission.bluetoothConnect]?.isGranted ?? false;
      final bool emettre =
          resultats[Permission.bluetoothAdvertise]?.isGranted ?? false;

      // Sur Android >= 12 :
      // - Une excavatrice a besoin de `emettre` (advertise) et `connecter`.
      // - Un DT/Spotter a besoin de `scan` et `connecter`.
      // Exiger les trois a la fois bloque un appareil dont l'OS n'accorde
      // que les permissions utiles a son role.
      if (scan || connecter || emettre) {
        return (scan && connecter) || (emettre && connecter);
      }

      // Aucune des trois accordee : soit Android < 12 (les permissions
      // dediees n'y existent pas), soit refus franc. On distingue avec la
      // localisation, seule voie du scan sur les anciennes versions.
      final bool localisation =
          resultats[Permission.locationWhenInUse]?.isGranted ?? false;
      return localisation;
    } catch (_) {
      // Plugin absent (desktop, tests) : on laisse la couche tenter sa
      // chance plutot que de bloquer l'application.
      return true;
    }
  }

  /// Vrai si l'utilisateur a coche « ne plus demander » : l'appelant peut
  /// alors proposer d'ouvrir les reglages systeme.
  static Future<bool> refuseDefinitivement() async {
    if (!_estAndroid) return false;
    try {
      final PermissionStatus statut = await Permission.bluetoothScan.status;
      return statut.isPermanentlyDenied;
    } catch (_) {
      return false;
    }
  }
}

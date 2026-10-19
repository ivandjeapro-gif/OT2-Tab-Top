import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

/// Demande des permissions **camera et galerie** au premier usage (point 4 du
/// reste-a-faire du rapport du 14/10 : "permissions runtime a chaud plutot
/// qu'a l'installation").
///
/// Sur Android, `image_picker` gere lui-meme la boite systeme quand on lui
/// laisse la main, mais une permission **prealablement refusee** fait echouer
/// silencieusement la capture. On verifie donc avant chaque capture :
/// - `camera` : obligatoire pour la source [ImageSource.camera] ;
/// - `photos` (media library, API 33+) : utile pour la galerie.
///
/// Strategie "a chaud" : la demande n'est posee QUE quand l'utilisateur tappe
/// `Picture` et choisit une source — jamais a l'installation, jamais en
/// rafale au demarrage. Sur les plateformes sans modele runtime (Windows,
/// web, iOS gere par le plugin), l'appel est un no-op qui rend `true`.
class PermissionsPhoto {
  PermissionsPhoto._();

  static bool get _estAndroid => !kIsWeb && Platform.isAndroid;

  /// Vrai si la permission [p] est accordee, ou demande a chaud sinon.
  ///
  /// Rend `false` si l'utilisateur refuse ou a coche "ne plus demander" :
  /// l'appelant affiche alors son message et peut proposer les reglages
  /// systeme via [ouvrirReglages].
  static Future<bool> accorder(Permission p) async {
    if (!_estAndroid) return true;
    try {
      final PermissionStatus statut = await p.status;
      if (statut.isGranted || statut.isLimited) return true;
      if (statut.isPermanentlyDenied) return false;
      final PermissionStatus apres = await p.request();
      return apres.isGranted || apres.isLimited;
    } catch (_) {
      // Plugin absent (tests, desktop) : on ne bloque jamais la saisie.
      return true;
    }
  }

  /// Permission camera accordee (ou acceptee a chaud).
  static Future<bool> camera() => accorder(Permission.camera);

  /// Permission galerie accordee (ou acceptee a chaud). `Permission.photos`
  /// n'existe qu'a partir d'Android 13 ; sur les versions plus anciennes le
  /// plugin rend un statut non pertinent que l'on traite comme accorde (la
  /// galerie y est couverte par le stockage, accorde a l'installation).
  static Future<bool> galerie() async {
    if (!_estAndroid) return true;
    try {
      final PermissionStatus statut = await Permission.photos.status;
      if (statut.isGranted || statut.isLimited) return true;
      final PermissionStatus apres = await Permission.photos.request();
      // Android < 13 : la permission n'existe pas et reste "denied" sans
      // boite de dialogue — ce n'est pas un refus, on laisse passer.
      if (apres.isGranted || apres.isLimited) return true;
      return apres.isPermanentlyDenied ? false : true;
    } catch (_) {
      return true;
    }
  }

  /// Vrai si l'utilisateur a coche "ne plus demander" : l'appelant propose
  /// alors d'ouvrir les reglages systeme.
  static Future<bool> refuseDefinitivement(Permission p) async {
    if (!_estAndroid) return false;
    try {
      return (await p.status).isPermanentlyDenied;
    } catch (_) {
      return false;
    }
  }
}

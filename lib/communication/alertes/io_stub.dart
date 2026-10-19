// Tas de repli pour l'import conditionnel de `dart:io` sur le web :
// `Platform` n'y existe pas, mais le code ne l'appelle jamais (la garde
// kIsWeb court-circuite avant). On declare juste le symbole pour que la
// compilation web passe.
class Platform {
  static bool get isAndroid => false;
  static bool get isIOS => false;
  static bool get isWindows => false;
}

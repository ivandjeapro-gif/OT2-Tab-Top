// Tas de repli pour l'import conditionnel de `package:web/web.dart` sur les
// plateformes non-web (Android, iOS, Windows) : ces symboles n'y existent
// pas, mais le code ne les utilise jamais (la garde kIsWeb court-circuite
// avant). On declare juste les noms de types/membres pour que la compilation
// Android/Windows passe.
//
// Meme logique que io_stub.dart : un squelette vide aligne sur les usages
// dans alerter.dart (web.window.speechSynthesis, SpeechSynthesis,
// SpeechSynthesisUtterance, SpeechSynthesisVoice).

class WindowWeb {
  const WindowWeb();
  SpeechSynthesis get speechSynthesis => const SpeechSynthesis();
}

class SpeechSynthesis {
  const SpeechSynthesis();
  void speak(SpeechSynthesisUtterance utterance) {}
  void cancel() {}
  List<SpeechSynthesisVoice> getVoices() => const <SpeechSynthesisVoice>[];
}

class SpeechSynthesisUtterance {
  SpeechSynthesisUtterance(String text);
  double volume = 1.0;
  double rate = 1.0;
  String lang = '';
  SpeechSynthesisVoice? voice;
}

class SpeechSynthesisVoice {
  String get name => '';
  String get lang => '';
}

const WindowWeb window = WindowWeb();

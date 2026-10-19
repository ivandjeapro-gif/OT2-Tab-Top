import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart' show kIsWeb, debugPrint;
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:vibration/vibration.dart';

// dart:io n'existe pas sur le web : import conditionnel, seules les
// references arentes par kIsWeb y sont evaluees.
import 'io_stub.dart'
    if (dart.library.io) 'dart:io' show Platform;

// package:web n'existe que sur la cible web : import conditionnel. Sur
// Android/Windows le stub declare les memes noms de types pour que la
// compilation passe ; le code reel ne s'execute jamais (kIsWeb == false).
import 'web_stub.dart' as web
    if (dart.library.js_interop) 'package:web/web.dart';

/// Canal d'alerte sonore et vibratoire (choix terrain : signal a chaque
/// mesure GPS tant que le DT reste hors du parcours).
///
/// Interface injectable comme [FournisseurPosition] : les tests branchent
/// [AlerteFactice] et comptent les declenchements au lieu d'attendre un
/// materiel qui vibre.
abstract class AlerteMetier {
  /// Joue un bip court + une vibration + la voix off du message d'alerte.
  /// Ne leve jamais : un capteur absent ou une plateforme sans audio
  /// n'arrete pas l'application.
  void jouer();

  /// Annonce le [message] d'alerte par la synthese vocale (voix off).
  /// Utilise aussi pour annoncer la sortie/retour sur parcours.
  Future<void> dire(String message) async {}

  /// Deverrouille l'audio du navigateur web (autoplay policy). No-op hors
  /// web ; a appeler sur le premier tap utilisateur.
  void deverrouillerAudioWeb() {}

  /// Libere les ressources systeme (lecteur audio). Vide par defaut.
  void fermer() {}
}

/// Compteur d'appels, pour les tests et le banc.
class AlerteFactice implements AlerteMetier {
  int appels = 0;

  /// Dernier message passe a [dire] (verifie dans les tests).
  String? dernierMessage;
  @override
  void jouer() => appels++;
  @override
  Future<void> dire(String message) async => dernierMessage = message;
  @override
  void deverrouillerAudioWeb() {}
  @override
  void fermer() {}
}

/// Implementation systeme : vibration (`vibration`) + bip WAV embarque
/// (`audioplayers`), avec repli silencieux partout ou la plateforme ne
/// supporte pas l'un des deux (Windows sans vibreur, tests sans audio).
class AlerteSysteme implements AlerteMetier {
  AlerteSysteme({this.cheminBip = 'sons/alerte.wav'});

  /// Fichier WAV joue a chaque declenchemet (asset du package).
  final String cheminBip;
  AudioPlayer? _lecteur;

  /// Synthese vocale (voix off). Creee paresseusement : flutter_tts peut
  /// lever des que l'on touche l'instance sur une plateforme sans moteur TTS.
  FlutterTts? _tts;

  /// Debounce de la voix off : pendant l'alerte, chaque mesure GPS rejoue
  /// le bip, mais la phrase complete ne doit pas se chevaucher elle-meme
  /// toutes les 2 s. Rejouee si le message change.
  String? _dernierTexte;
  DateTime _dernierDire = DateTime(2000);

  /// Deverrouillage audio du navigateur web.
  ///
  /// Chrome et Edge bloquent speechSynthesis.speak() tant que l'utilisateur
  /// n'a pas interagi avec la page : une alerte declenchee automatiquement
  /// au chargement est rejetee silencieusement. On spoke une utterance vide
  /// sur le premier tap pour deverrouiller le contexte audio ; ensuite les
  /// alertes passent sans interaction.
  bool _audioDebloqueWeb = false;

  /// Deverrouille l'audio du navigateur. A appeler sur le premier tap de
  /// l'utilisateur (GestureRecognizer / onTapDown de l'ecran d'accueil).
  @override
  void deverrouillerAudioWeb() {
    if (!kIsWeb || _audioDebloqueWeb) return;
    try {
      final web.SpeechSynthesis synth = web.window.speechSynthesis;
      final web.SpeechSynthesisUtterance u =
          web.SpeechSynthesisUtterance(' ');
      u.volume = 0.0;
      u.rate = 10.0; // quasi instantane
      synth.speak(u);
      _audioDebloqueWeb = true;
    } catch (_) {
      // Navigateur sans synthese : rien a deverrouiller.
    }
  }

  @override
  void jouer() {
    _vibrer();
    _bip();
  }

  @override
  Future<void> dire(String message) async {
    // Anti-spam : meme message pendant 25 s = une seule annonce.
    final DateTime maintenant = DateTime.now();
    if (message == _dernierTexte &&
        maintenant.difference(_dernierDire) < const Duration(seconds: 25)) {
      return;
    }
    _dernierTexte = message;
    _dernierDire = maintenant;

    try {
      if (kIsWeb) {
        // Web : utiliser la Web Speech API et les voix disponibles dans le
        // navigateur (dont Microsoft Charline fr-BE sur Edge). Si l'audio
        // n'a pas encore ete deverrouille par un tap, sSpeak est rejete :
        // on retente apres avoir force le deverrouillage.
        if (!_audioDebloqueWeb) deverrouillerAudioWeb();
        await _direWeb(message);
        return;
      }
      final FlutterTts tts = _tts ??= FlutterTts();
      // Android embarque Google TTS : voix francaise native disponible.
      // Sur Windows on garde en-US (Zira, la seule voix de la machine de
      // demonstration) ; le message reste audible et comprehensible.
      final String langue = (!kIsWeb && Platform.isAndroid) ? 'fr-FR' : 'en-US';
      await tts.setLanguage(langue);
      await tts.setSpeechRate(0.45);
      await tts.setVolume(1.0);
      await tts.setPitch(1.0);
      await tts.speak(message);
    } catch (_) {
      // Pas de moteur TTS (bureau sans voix installee) :
      // le bip et la vibration restent en place.
    }
  }

  /// Voix off sur le web, par la Web Speech API du navigateur.
  /// Attend le chargement asynchrone des voix avant de choisir la voix
  /// francaise installee (sur Edge, Charline fr-BE est disponible).
  Future<void> _direWeb(String message) async {
    try {
      final web.SpeechSynthesis synth = web.window.speechSynthesis;
      synth.cancel();

      web.SpeechSynthesisVoice? voix = _choisirVoixWeb(synth);
      // Certains navigateurs ne publient leurs voix qu'apres voiceschanged.
      for (int i = 0; voix == null && i < 20; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        voix = _choisirVoixWeb(synth);
      }

      final web.SpeechSynthesisUtterance u =
          web.SpeechSynthesisUtterance(message);
      if (voix != null) {
        u.voice = voix;
        u.lang = voix.lang;
      } else {
        u.lang = 'fr-FR';
      }
      u.rate = 0.9;
      u.volume = 1.0;
      synth.speak(u);
    } catch (_) {
      // Navigateur sans synthese vocale : rien, le bip reste en place.
    }
  }

  /// Privilegie Charline (fr-BE), puis une voix fr-FR, puis toute voix
  /// francaise. Repli ensuite sur l'anglais ou la premiere voix disponible.
  web.SpeechSynthesisVoice? _choisirVoixWeb(web.SpeechSynthesis synth) {
    final List<web.SpeechSynthesisVoice> liste =
        (synth.getVoices() as dynamic).toDart;
    if (liste.isEmpty) return null;

    for (final web.SpeechSynthesisVoice v in liste) {
      if (v.name.toLowerCase().contains('charline') &&
          v.lang.toLowerCase().startsWith('fr')) {
        return v;
      }
    }
    for (final web.SpeechSynthesisVoice v in liste) {
      if (v.lang.toLowerCase() == 'fr-fr') return v;
    }
    for (final web.SpeechSynthesisVoice v in liste) {
      if (v.lang.toLowerCase().startsWith('fr')) return v;
    }
    for (final web.SpeechSynthesisVoice v in liste) {
      if (v.lang.toLowerCase().startsWith('en')) return v;
    }
    return liste.first;
  }

  void _vibrer() {
    // try/catch systematique : vibration n'est pas implemente sur toutes les
    // plateformes, et l'alerte doit rester un bip meme sans vibreur.
    try {
      Vibration.vibrate(duration: 350);
    } catch (_) {
      try {
        // Repli : retour haptique du framework (aucune permission requise).
        HapticFeedback.vibrate();
      } catch (_) {}
    }
  }

  void _bip() {
    // try/catch partout : y compris l'acces a [Platform], indisponible sur
    // certaines cibles — `jouer()` ne doit jamais lever.
    try {
      // Web exclus : audioplayers desktop lit les bytes, pas le web.
      if (kIsWeb) {
        final AudioPlayer lecteur = _lecteur ??= AudioPlayer();
        lecteur.stop().then(
              (void _) => lecteur.play(AssetSource(cheminBip)),
              onError: (Object _) {},
            );
        return;
      }
      if (!Platform.isAndroid &&
          !Platform.isIOS &&
          !Platform.isWindows) {
        return;
      }
      final AudioPlayer lecteur = _lecteur ??= AudioPlayer();
      // BytesSource : lecture des octets de l'asset via rootBundle puis
      // decodage direct. Plus fiable qu'AssetSource sur Windows, ou le
      // chemin d'asset a change silencieusement selon les versions.
      rootBundle.load('assets/$cheminBip').then((ByteData donnees) {
        lecteur.stop().then((void _) {
          lecteur
              .play(BytesSource(donnees.buffer.asUint8List()))
              .catchError((Object e) => debugPrint('[Alerte] bip KO: $e'));
        });
      }, onError: (Object e) {
        // Repli : AssetSource classique si rootBundle echoue.
        debugPrint('[Alerte] asset KO ($e), repli AssetSource');
        lecteur.play(AssetSource(cheminBip)).catchError((Object e2) {
          debugPrint('[Alerte] bip repli KO: $e2');
        });
      });
    } catch (e) {
      debugPrint('[Alerte] bip exception: $e');
    }
  }

  @override
  void fermer() {
    _lecteur?.dispose();
    _lecteur = null;
    try {
      _tts?.stop();
    } catch (_) {}
    _tts = null;
    if (kIsWeb) {
      try {
        web.window.speechSynthesis.cancel();
      } catch (_) {}
    }
  }
}

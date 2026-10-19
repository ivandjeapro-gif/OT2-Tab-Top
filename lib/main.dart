import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqflite_common_ffi_web/sqflite_ffi_web.dart';

import 'screens/splash_screen.dart';
import 'state/session.dart';
import 'theme/app_theme.dart';

/// Taille de reference de la maquette : tablette 14 pouces en 2240 x 1440
/// pixels. `flutter_screenutil` raisonne en pixels **logiques** : a la densite
/// 2,0 de cette tablette, la reference vaut 1120 x 720. C'est le format dans
/// lequel les maquettes ont ete dessinees, donc l'echelle vaut 1,0 dessus.
const Size kTailleReference = Size(1120, 720);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Base de donnees : sqflite ne tourne qu'en mobile. Sur desktop c'est
  // sqflite_common_ffi qui porte le fichier SQLite, sur web la variante
  // s'appuie sur le worker partage sqflite_sw.js + sqlite3.wasm livres dans
  // web/ (meme schema, meme code de base — seule l'usine change).
  if (kIsWeb) {
    databaseFactory = databaseFactoryFfiWeb;
  } else if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }
  runApp(const OreApp());
}

class OreApp extends StatefulWidget {
  const OreApp({super.key});

  @override
  State<OreApp> createState() => _OreAppState();
}

class _OreAppState extends State<OreApp> {
  final Session _session = Session();

  @override
  void dispose() {
    _session.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Adaptation automatique a la taille de l'ecran ET a l'orientation :
    // ScreenUtilInit ecoute les variations de MediaQuery et recalcule
    // l'echelle a chaque rotation ou redimensionnement. `minTextAdapt` fait
    // suivre les polices (le texte ne devient ni minuscule ni geant), et
    // `splitScreenMode` tient compte du clavier et du multi-fenetres.
    return ScreenUtilInit(
      designSize: kTailleReference,
      minTextAdapt: true,
      splitScreenMode: true,
      builder: (context, child) => MaterialApp(
        title: 'ORE Tracking',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light,
        home: SplashScreen(session: _session),
      ),
    );
  }
}

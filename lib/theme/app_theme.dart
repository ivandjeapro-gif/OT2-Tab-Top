import 'package:flutter/material.dart';

/// Palette echantillonnee sur les maquettes.
class AppColors {
  static const Color bar = Color(0xFF989A9B);
  static const Color tan = Color(0xFFEDCD8B);
  static const Color slate = Color(0xFF4A5162);
  static const Color greyButton = Color(0xFFC7C9CB);
  static const Color green = Color(0xFF72C877);
  static const Color greenStrong = Color(0xFF5FD008);
  static const Color red = Color(0xFFE53935);
  /// Etat intermediaire des badges (CDC §20) : couche demarree, en recherche.
  static const Color orange = Color(0xFFE8871E);
  static const Color border = Color(0xFFD1D3D4);
  /// Texte secondaire des maquettes (details, hints, legendes).
  static const Color greyText = Color(0xFF9A9DA1);
  /// Fond des zones desactivees / rappel de contexte.
  static const Color greyBg = Color(0xFFF3F4F5);
  static const Color darkSquare = Color(0xFF2E2E2E);
  static const Color ink = Color(0xFF1F2430);
  static const Color gold = Color(0xFFE8A200);
  static const Color paper = Color(0xFFFFFFFF);
}

/// Les maquettes utilisent une police serif pour les titres et les valeurs.
const String kSerif = 'serif';
const String kSans = 'Roboto';

class AppTheme {
  static ThemeData get light {
    return ThemeData(
      useMaterial3: false,
      scaffoldBackgroundColor: AppColors.paper,
      fontFamily: kSans,
      colorScheme: ColorScheme.fromSwatch().copyWith(
        primary: AppColors.slate,
        secondary: AppColors.tan,
      ),
      splashFactory: InkRipple.splashFactory,
    );
  }
}

extension SpacedText on String {
  /// Les libelles des maquettes sont espaces : "B l a s t".
  String get spaced {
    final buffer = StringBuffer();
    for (var i = 0; i < length; i++) {
      if (i > 0) buffer.write(' ');
      buffer.write(this[i]);
    }
    return buffer.toString();
  }
}

import 'dart:async';

import 'package:flutter/material.dart';

import '../state/session.dart';
import '../theme/app_theme.dart';
import '../theme/responsive.dart';
import 'login_screen.dart';

/// Splash : logo ORE Tracking + barre de progression.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key, required this.session});

  final Session session;

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  Timer? _timer;

  /// Mode DEMONSTRATION (presentation offroad) : 5 taps rapides sur le logo
  /// pendant le splash activent le scenario GPS simulé (sortie de parcours
  /// en boucle, bip + vibration, bandeau rouge). Sans tap, demarrage normal.
  int _taps = 0;
  bool demoOffroad = false;

  /// Ouverture du fichier local (CDC §13) : lancee des le premier frame, de
  /// sorte que les 3 s de barre de progression servent aussi a charger la base.
  late final Future<void> _base;

  @override
  void initState() {
    super.initState();
    _base = widget.session.ouvrirBase();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2600),
    )..forward();
    _timer = Timer(const Duration(milliseconds: 3000), _suivant);
  }

  /// 5 taps sur le logo = mode demo. La base est reouverte avec le scenario :
  /// ouvrirBase remplace le service de position avant le premier ecran.
  void _tapLogo() {
    // Premier tap = deverrouillage de l'audio du navigateur web : sans lui,
    // Chrome/Edge rejettent speechSynthesis.speak() des alertes automatiques.
    widget.session.alerter.deverrouillerAudioWeb();
    _taps++;
    if (_taps >= 5 && !demoOffroad) {
      demoOffroad = true;
      _base.then((_) => widget.session.ouvrirBase(demoOffroad: true));
    }
  }

  void _suivant() async {
    // L'ecran de connexion lit les identifiants enrroles dans la base :
    // il ne peut pas s'afficher avant qu'elle soit chargee.
    await _base;
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => LoginScreen(session: widget.session),
      ),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final MiseEnPage mise = MiseEnPage.depuis(context);
    final Size fenetre = MediaQuery.sizeOf(context);
    final double largeur = fenetre.width;

    // Plafonne le logo a 40% de la hauteur de la fenetre : au-dela, les
    // Spacer du bas tombent a zero et la Column deborde.
    final double hauteurLogo = mise.hauteurLogoSplash < fenetre.height * 0.4
        ? mise.hauteurLogoSplash
        : fenetre.height * 0.4;

    // Sans SizedBox(width: double.infinity), une Column ne prend que la
    // largeur de son plus large enfant (ici la barre) et se retrouve calee a
    // gauche. On impose donc la largeur maximale de la fenetre.
    return Scaffold(
      backgroundColor: AppColors.paper,
      body: SafeArea(
        child: SizedBox(
          width: double.infinity,
          child: Column(
            children: [
              const Spacer(flex: 3),
              GestureDetector(
                // Mode demo : 5 taps rapides sur le logo pendant le splash.
                onTap: _tapLogo,
                child: Image.asset(
                  'assets/images/logo_ore_tracking.png',
                  height: hauteurLogo,
                  fit: BoxFit.contain,
                ),
              ),
              const Spacer(flex: 4),
              if (demoOffroad)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    'MODE DEMO OFFROAD',
                    style: TextStyle(
                      fontFamily: kSerif,
                      fontWeight: FontWeight.w800,
                      color: AppColors.red,
                      fontSize: 16,
                    ),
                  ),
                ),
              SizedBox(
                // `.clamp(0, ...)` : sur une fenetre de largeur nulle (fenetre
                // minimisée, premiere frame avant mesure), le produit tombe a 0
                // et la boite de la barre serait vide — la valeur n'est jamais
                // negative, donc aucun Container ne peut recevoir une
                // dimension invalide.
                width: (largeur * 0.4).clamp(0.0, largeur),
                child: Container(
                  height: 14,
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.black, width: 1.5),
                  ),
                  alignment: Alignment.centerLeft,
                  // Sans AnimatedBuilder, personne n'ecoute le controller :
                  // build n'est pas rappelle et la barre reste figee a 0
                  // pendant que l'ecran passe a la suite au bout de 3 s.
                  child: AnimatedBuilder(
                    animation: _controller,
                    builder: (context, _) => FractionallySizedBox(
                      widthFactor: _controller.value,
                      child: Container(color: AppColors.gold),
                    ),
                  ),
                ),
              ),
              SizedBox(height: 56 * mise.k),
            ],
          ),
        ),
      ),
    );
  }
}

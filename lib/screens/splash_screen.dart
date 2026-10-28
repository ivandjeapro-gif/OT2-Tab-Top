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

  /// Le logo n'est plus interactif : le mode demo est debranche (demande du
  /// 21/10 — « je ne veux aucun demo »). Un 5-taps accidentel avait active
  /// le scenario fictif sur une tablette de production (GPS simule, alerte
  /// « sortie de route » codee en dur). Le tap conserve uniquement le
  /// deverrouillage audio web.
  void _tapLogo() {
    widget.session.alerter.deverrouillerAudioWeb();
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
                // Deverrouillage audio web au tap : la page ne joue un son
                // qu'apres une interaction utilisateur (politique navigateur).
                onTap: _tapLogo,
                child: Image.asset(
                  'assets/images/logo_ore_tracking.png',
                  height: hauteurLogo,
                  fit: BoxFit.contain,
                ),
              ),
              const Spacer(flex: 4),
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

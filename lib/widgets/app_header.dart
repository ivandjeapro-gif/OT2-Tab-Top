import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/responsive.dart';

/// Bandeau gris du haut : logo Lafigue + filet + logo ORE Tracking.
class AppHeader extends StatelessWidget {
  const AppHeader({super.key, this.onExit});

  /// Action de deconnexion / sortie du profil vers l'accueil.
  final VoidCallback? onExit;

  @override
  Widget build(BuildContext context) {
    final MiseEnPage mise = MiseEnPage.depuis(context);
    final double k = mise.k;

    return Container(
      width: double.infinity,
      color: AppColors.bar,
      height: mise.hauteurEntete,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 1. Logos parfaitement centres sur toute la largeur de l'ecran.
          Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Image.asset(
                  'assets/images/logo_lafigue.png',
                  height: (46 * k).clamp(24.0, 46.0),
                  fit: BoxFit.contain,
                ),
                SizedBox(width: 28 * k),
                Container(
                  width: 1.5,
                  height: (52 * k).clamp(28.0, 52.0),
                  color: Colors.white,
                ),
                SizedBox(width: 28 * k),
                Image.asset(
                  'assets/images/logo_ore_tracking.png',
                  height: (58 * k).clamp(30.0, 58.0),
                  fit: BoxFit.contain,
                ),
              ],
            ),
          ),
          // 2. Bouton Exit cale tout a droite de l'ecran.
          if (onExit != null)
            Positioned(
              right: 18 * k,
              top: 0,
              bottom: 0,
              child: Center(
                child: TextButton.icon(
                  key: const ValueKey<String>('bouton-exit'),
                  onPressed: onExit,
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.white,
                    backgroundColor: Colors.white.withValues(alpha: 0.18),
                    padding: EdgeInsets.symmetric(
                      horizontal: (14 * k).clamp(10.0, 16.0),
                      vertical: (8 * k).clamp(6.0, 10.0),
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(4),
                      side: const BorderSide(color: Colors.white38),
                    ),
                  ),
                  icon: Icon(
                    Icons.logout,
                    size: (20 * k).clamp(16.0, 22.0),
                    color: Colors.white,
                  ),
                  label: Text(
                    'Exit',
                    style: TextStyle(
                      fontFamily: kSerif,
                      fontSize: (14 * k).clamp(12.0, 16.0),
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Pied de page gris des ecrans de connexion (logo Lafigue blanc).
class AppFooter extends StatelessWidget {
  const AppFooter({super.key, this.mise});

  final MiseEnPage? mise;

  @override
  Widget build(BuildContext context) {
    final MiseEnPage m = mise ?? MiseEnPage.depuis(context);
    return Container(
      color: AppColors.bar,
      height: m.hauteurBandeau,
      alignment: Alignment.center,
      child: Image.asset(
        'assets/images/logo_lafigue.png',
        height: 44 * m.k,
        fit: BoxFit.contain,
      ),
    );
  }
}

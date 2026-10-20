import 'package:flutter/material.dart';

import '../screens/login_screen.dart';
import '../state/session.dart';
import '../theme/app_theme.dart';
import '../theme/responsive.dart';
import '../widgets/app_header.dart';
import '../widgets/notification_ticker.dart';
import '../widgets/status_badges.dart';
import '../widgets/supervision_reseau.dart';
import '../widgets/voyants_entete.dart';

/// Gabarit commun des trois ecrans profils :
/// bandeau logo + contenu + bandeau de notifications.
class ProfileShell extends StatelessWidget {
  const ProfileShell({
    super.key,
    required this.session,
    required this.body,
    this.voyants,
  });

  final Session session;
  final Widget body;

  /// Voyants poses dans le bandeau du haut, a gauche du logo.
  /// Null = profil sans voyants.
  final ProfilVoyants? voyants;

  Future<void> _confirmerSortie(BuildContext context) async {
    final bool? quitter = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('Quitter la session ?'),
        content: Text(
          session.profile != null
              ? 'Voulez-vous fermer la session de ${session.profile!.libelle} (${session.deviceName}) et revenir a l\'ecran de connexion ?'
              : 'Voulez-vous vous deconnecter et revenir a l\'ecran de connexion ?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Annuler'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.slate,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Deconnecter'),
          ),
        ],
      ),
    );

    if (quitter == true && context.mounted) {
      session.disconnect();
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => LoginScreen(session: session),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.paper,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AppHeader(
              onExit: () => _confirmerSortie(context),
              voyants: voyants == null
                  ? null
                  : VoyantsEntete(session: session, profil: voyants!),
            ),
            Expanded(child: body),
            Row(
              children: [
                // Fleche d'echange a gauche : animee pendant un envoi
                // effectif vers le DT (Wi-Fi ou BLE). Ouvre la supervision
                // reseau (CDC §21/§22).
                DataExchangeButton(
                  onPressed: () => SupervisionReseau.montrer(context, session),
                  session: session,
                ),
                Expanded(
                  child: NotificationTicker(session: session),
                ),
                // Nuage a droite : anime pendant une synchro serveur (4G).
                SyncCloudIcon(session: session),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Espace d'affichage carte (zone vide dans les maquettes).
class MapPlaceholder extends StatelessWidget {
  const MapPlaceholder({super.key});

  @override
  Widget build(BuildContext context) {
    final double k = MiseEnPage.depuis(context).k;
    return Container(
      width: double.infinity,
      height: double.infinity,
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.border, width: 2),
        color: Colors.white,
      ),
      alignment: Alignment.center,
      child: Icon(
        Icons.map_outlined,
        size: (96 * k).clamp(40.0, 96.0),
        color: AppColors.border,
      ),
    );
  }
}

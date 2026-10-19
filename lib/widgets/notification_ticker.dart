import 'dart:async';

import 'package:flutter/material.dart';

import '../state/session.dart';
import '../theme/app_theme.dart';
import '../theme/responsive.dart';

/// Bandeau de notification defilant (bas de l'ecran).
///
/// Deux regimes :
/// - **alerte active** ([Session.alerteActive]) : le message d'alerte est
///   force en rouge, plein cadre, sans defilement — une sortie de parcours
///   ne doit jamais etre noyee entre deux notifications de synchro ;
/// - **regime normal** : le ticker fait defiler les derniers evenements
///   reels journalises par la session (connexions, ACK, synchro serveur).
///   Plus aucun message de demo n'est produit par l'application.
class NotificationTicker extends StatefulWidget {
  const NotificationTicker({super.key, required this.session});

  final Session session;

  @override
  State<NotificationTicker> createState() => _NotificationTickerState();
}

class _NotificationTickerState extends State<NotificationTicker> {
  Timer? _timer;
  int _index = 0;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 4), (_) {
      if (!mounted) return;
      final total = widget.session.notifications.length;
      if (total == 0) return;
      setState(() => _index = (_index + 1) % total);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final MiseEnPage mise = MiseEnPage.depuis(context);
    final bool enAlerte = widget.session.alerteActive;
    final bool enNotification = widget.session.notificationActive;

    // Alerte hors parcours : priorite absolue sur tout le reste.
    if (enAlerte) {
      return Container(
        height: mise.hauteurTicker,
        decoration: const BoxDecoration(color: AppColors.red),
        alignment: Alignment.center,
        clipBehavior: Clip.antiAlias,
        child: Text(
          widget.session.alerteCourante,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w700,
            fontSize: (26 * mise.k).clamp(18.0, 30.0),
            letterSpacing: 0.5,
          ),
        ),
      );
    }

    // Notification Boss (ordre du bureau) : bandeau rouge plein cadre,
    // installe par la session a la reception (HTTP ou lien local). Reste
    // jusqu'a l'acquittement de l'operateur, avec un bouton « OK » qui
    // retombe le bandeau — la notification reste en base (historique).
    if (enNotification) {
      return Container(
        height: mise.hauteurTicker,
        decoration: const BoxDecoration(color: AppColors.red),
        alignment: Alignment.center,
        clipBehavior: Clip.antiAlias,
        child: Row(
          children: [
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 10),
              child: Icon(Icons.priority_high, color: Colors.white, size: 22),
            ),
            Expanded(
              child: Text(
                widget.session.messageNotification,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  fontSize: (17 * mise.k).clamp(11.0, 17.0),
                  letterSpacing: 0.5,
                ),
              ),
            ),
            TextButton(
              onPressed: widget.session.acquitterNotification,
              child: const Text(
                'OK',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
      );
    }

    final messages = widget.session.notifications;

    // Synchro en cours : le dernier message poussé prend le dessus sur la
    // rotation — l'operateur voit « Synchronisation demandee... » puis les
    // resultats de chaque passe au fil de l'eau, au lieu de les noyer dans
    // le defilement. La rotation reprend des que la synchro est terminee.
    if (widget.session.synchroActive && messages.isNotEmpty) {
      final String courant = messages.last;
      return Container(
        height: mise.hauteurTicker,
        decoration: const BoxDecoration(color: AppColors.slate),
        alignment: Alignment.center,
        clipBehavior: Clip.antiAlias,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 250),
          child: Text(
            courant,
            key: ValueKey<String>(courant),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w700,
              fontSize: (17 * mise.k).clamp(11.0, 17.0),
              letterSpacing: 0.5,
            ),
          ),
        ),
      );
    }

    // Regime normal : defilement des evenements reels.
    final message = messages.isEmpty ? '' : messages[_index % messages.length];
    return Container(
      height: mise.hauteurTicker,
      // color: + clipBehavior: leve l'assertion de Container (le clip exige
      // un decoration). On passe donc par BoxDecoration.
      decoration: const BoxDecoration(color: AppColors.bar),
      alignment: Alignment.center,
      clipBehavior: Clip.antiAlias,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 450),
        switchInCurve: Curves.easeOut,
        transitionBuilder: (child, animation) => FadeTransition(
          opacity: animation,
          child: SlideTransition(
            position: Tween<Offset>(begin: const Offset(0.6, 0), end: Offset.zero)
                .animate(animation),
            child: child,
          ),
        ),
        child: Text(
          message,
          key: ValueKey<String>(message),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Colors.white,
            fontSize: (17 * mise.k).clamp(11.0, 17.0),
            letterSpacing: 0.5,
          ),
        ),
      ),
    );
  }
}

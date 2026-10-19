import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Etat d'une couche de communication, dans les trois valeurs que les badges
/// affichent (CDC §20) :
///
/// - [arret] : rien n'est parti, aucun retour — **rouge** ;
/// - [recherche] : demarre, en attente d'un lien ou d'un acquittement —
///   **orange** ;
/// - [connecte] : lien etabli ou dernier retour recu — **vert**.
///
/// Une seule convention, valable pour le Wi-Fi, la 4G, le BLE et la couche
/// P2P : un badge ne devrait jamais afficher vert sans qu'un etat reel
/// (association, client connecte, reponse serveur) l'ait mis dans cet etat.
enum EtatCouche {
  arret,
  recherche,
  connecte;

  /// Couleur du badge pour cet etat.
  Color get couleur => switch (this) {
        EtatCouche.arret => AppColors.red,
        EtatCouche.recherche => AppColors.orange,
        EtatCouche.connecte => AppColors.green,
      };

  /// Libelle court, dans la langue de la maquette.
  String get libelle => switch (this) {
        EtatCouche.arret => 'offline',
        EtatCouche.recherche => 'search',
        EtatCouche.connecte => 'online',
      };
}

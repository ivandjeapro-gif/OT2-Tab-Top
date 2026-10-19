import 'package:flutter/material.dart';

import '../state/etat_couche.dart';
import '../state/session.dart';
import '../theme/app_theme.dart';
import '../theme/responsive.dart';

/// Panneau de supervision reseau (CDC §21/§22).
///
/// Un seul endroit ou lire l'etat des couches de communication :
/// - §21 : file des evenements PENDING en attente du serveur, derniere
///   synchro HTTPS reussie ;
/// - §22 : journal technique BLE/Wi-Fi tenu par la base locale (connexions,
///   RSSI, doublons), liste des excavatrices (TAB 3) avec le RSSI de chaque lien.
///
/// Le panneau ne modifie rien : c'est une lecture de la session, l'ecriture
/// (demarrage des couches, rejets, acquittements) reste dans les gateways.
class SupervisionReseau extends StatelessWidget {
  const SupervisionReseau({super.key, required this.session});

  final Session session;

  /// Ouvre le panneau en feuille modale pleine largeur au-dessus de l'ecran.
  static Future<void> montrer(BuildContext context, Session session) {
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.paper,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(8)),
      ),
      builder: (_) => SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.75,
        child: SupervisionReseau(session: session),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final double k = MiseEnPage.depuis(context).k;
    final List<String> journal = session.base.journalBle;

    return Padding(
      padding: EdgeInsets.all(16 * k),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Supervision reseau',
                  style: TextStyle(
                    fontFamily: kSerif,
                    fontSize: (24 * k).clamp(18.0, 24.0),
                    fontWeight: FontWeight.w700,
                    color: AppColors.ink,
                  ),
                ),
              ),
              IconButton(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
          SizedBox(height: 8 * k),
          Wrap(
            spacing: 10 * k,
            runSpacing: 8 * k,
            children: [
              _Etiquette(
                k: k,
                icone: Icons.bluetooth,
                etat: session.etatBle,
                texte: session.bleActif
                    ? (session.liensBle > 0
                        ? 'BLE : ${session.liensBle} excavatrice(s) connectée(s)'
                        : 'BLE : actif, aucune excavatrice')
                    : 'BLE : inactif',
              ),
              _Etiquette(
                k: k,
                icone: Icons.wifi,
                etat: session.etatWifiP2p,
                texte: session.wifiActif
                    ? (session.liensWifi > 0
                        ? 'Wi-Fi : ${session.liensWifi} spotter(s) connecté(s)'
                        : 'Wi-Fi : actif, aucun spotter')
                    : 'Wi-Fi : inactif',
              ),
              _Etiquette(
                k: k,
                icone: Icons.cloud_upload_outlined,
                etat: session.etat4G,
                texte: 'Serveur : ${session.enAttente} evenement(s) en attente'
                    '${session.derniereSynchro == null ? '' : ' - derniere synchro ${_heure(session.derniereSynchro!)}'}',
              ),
            ],
          ),
          SizedBox(height: 8 * k),
          if (session.rssiTab3.isNotEmpty) ...[
            Text(
              'Liens excavatrice (RSSI, CDC §8 : entree -70 / sortie -80 dBm)',
              style: TextStyle(
                fontFamily: kSerif,
                fontSize: (15 * k).clamp(12.0, 15.0),
                color: AppColors.ink,
                fontWeight: FontWeight.w700,
              ),
            ),
            ...session.rssiTab3.entries.map(
              (entry) => Padding(
                padding: EdgeInsets.only(top: 4 * k),
                child: Text(
                  '${entry.key} : ${entry.value} dBm',
                  style: TextStyle(
                    fontFamily: kSerif,
                    fontSize: (14 * k).clamp(11.0, 14.0),
                    color: AppColors.ink,
                  ),
                ),
              ),
            ),
            SizedBox(height: 8 * k),
          ],
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                border: Border.all(color: AppColors.border),
                color: Colors.white,
              ),
              child: journal.isEmpty
                  ? Center(
                      child: Text(
                        'Aucun evenement reseau journalise',
                        style: TextStyle(
                          fontFamily: kSerif,
                          fontSize: (14 * k).clamp(11.0, 14.0),
                          color: const Color(0xFF9A9DA1),
                        ),
                      ),
                    )
                  : ListView.builder(
                      padding: EdgeInsets.all(8 * k),
                      itemCount: journal.length,
                      itemBuilder: (context, index) => Text(
                        journal[index],
                        style: TextStyle(
                          fontFamily: kSans,
                          fontSize: (12 * k).clamp(10.0, 12.0),
                          color: AppColors.ink,
                        ),
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  static String _heure(DateTime moment) {
    String deux(int v) => v.toString().padLeft(2, '0');
    return '${deux(moment.hour)}:${deux(moment.minute)}:${deux(moment.second)}';
  }
}

/// Puce d'etat en tete du panneau : icone + texte, couleur selon l'etat
/// de la couche (CDC §20 : rouge / orange / vert).
class _Etiquette extends StatelessWidget {
  const _Etiquette({
    required this.k,
    required this.icone,
    required this.etat,
    required this.texte,
  });

  final double k;
  final IconData icone;
  final EtatCouche etat;
  final String texte;

  @override
  Widget build(BuildContext context) {
    final Color color = etat.couleur;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 10 * k, vertical: 6 * k),
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.border),
        color: Colors.white,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icone, size: (18 * k).clamp(14.0, 18.0), color: color),
          SizedBox(width: 6 * k),
          Text(
            texte,
            style: TextStyle(
              fontFamily: kSerif,
              fontSize: (14 * k).clamp(11.0, 14.0),
              color: AppColors.ink,
            ),
          ),
        ],
      ),
    );
  }
}

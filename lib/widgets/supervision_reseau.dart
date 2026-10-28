import 'package:flutter/material.dart';
import '../data/base_locale.dart';
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

    // LA FENETRE ECOUTE LA SESSION.
    //
    // Bug corrige le 27/10 : le journal etait bien ecrit (verifie en base :
    // « BLE gateway demarre », « BLE 1500-3 RSSI -54 », « BLE 1500-3
    // connecte »), mais ce panneau le lisait UNE FOIS a l'ouverture et ne se
    // reconstruisait plus. L'operateur voyait donc « Aucun evenement reseau
    // journalise » alors que le flux fonctionnait — le pire des diagnostics.
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) => _contenu(context, k),
    );
  }

  Widget _contenu(BuildContext context, double k) {
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
              // On n'affiche QUE les transports cochés dans les Paramètres :
              // un mode désactivé n'existe pas pour l'utilisateur, il ne
              // génère ni étiquette « inactif » ni fausse alerte.
              if (session.transportBleActif)
                _Etiquette(
                  k: k,
                  icone: Icons.bluetooth,
                  etat: session.etatBle,
                  texte: session.bleActif
                      ? (session.liensBle > 0
                          // Le libelle depend du ROLE LOCAL : une excavatrice
                          // recoit des DT, un DT voit une excavatrice. Le meme
                          // compteur liait les deux et affichait « 1 excavatrice
                          // connectee » DANS L'EXCAVATRICE elle-meme.
                          ? 'BLE : ${session.liensBle} ${_nomPair(session)} connecté(s)'
                          : 'BLE : actif, aucun ${_nomPair(session)}')
                      : 'BLE : inactif',
                ),
              // XBee : meme regle que partout ailleurs — un transport
              // decoche n'existe pas a l'ecran. Ce panneau l'omettait alors
              // que l'entete du DT et la section Parametres le proposent,
              // si bien qu'un XBee en panne n'etait visible nulle part.
              if (session.transportXbeeActif)
                _Etiquette(
                  k: k,
                  icone: Icons.settings_input_antenna,
                  etat: session.etatXbee,
                  texte: session.xbeeActif
                      ? 'XBee : ${session.etatXbee.libelle}'
                      : 'XBee : inactif',
                ),
              if (session.transportHotspotActif &&
                  !session.transportPrioritaireActif)
                _Etiquette(
                  k: k,
                  icone: Icons.wifi,
                  etat: session.etatWifiP2p,
                  texte: _texteWifi(session),
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

  /// Nom du pair vu par L'APPAREIL LOCAL, pour les libelles BLE.
  ///
  /// Une excavatrice recoit des DT ; un DT (ou un spotter) voit une
  /// excavatrice. Le texte etait figé sur « excavatrice » : l'excavatrice
  /// annoncait « 1 excavatrice connectee » en parlant d'elle-meme — elle doit
  /// dire « 1 DT connecte ».
  static String _nomPair(Session session) {
    final String role =
        (session.profile?.roleCdc ?? '').trim().toUpperCase();
    final bool localEstExcavatrice =
        BaseLocale.estTab3(role) || role == 'EXCAVATOR';
    return localEstExcavatrice ? 'DT' : 'excavatrice';
  }

  /// Texte du badge Wi-Fi, NOMINATIF (option B).
  ///
  /// Le Wi-Fi est un bus PARTAGE : une excavatrice recoit des DT **et** des
  /// spotters. Un libelle au singulier (« aucun DT ») mentait quand un
  /// spotter etait present, et inversement. Cote client, on nomme le serveur
  /// (l'excavatrice) ou on signale l'absence de lien.
  static String _texteWifi(Session session) {
    if (!session.wifiActif) return 'Wi-Fi : inactif';
    final Map<String, int> parRole = session.wifiParRole;
    if (parRole.isEmpty) {
      if (session.liensWifi > 0) {
        return 'Wi-Fi : ${session.liensWifi} client(s) connecte(s)';
      }
      return _localEstExcavatrice(session)
          ? 'Wi-Fi : actif, aucun client'
          : 'Wi-Fi : actif, non connecte a l\'excavatrice';
    }
    // Repartition nominative, ordre stable : DT, SPOT, puis le reste.
    final List<String> morceaux = <String>[];
    for (final String role in <String>['DT', 'SPOT', 'EXCAVATOR']) {
      final int n = parRole[role] ?? 0;
      if (n == 0) continue;
      morceaux.add('$n ${_nomRole(role)}');
    }
    for (final MapEntry<String, int> e in parRole.entries) {
      if (<String>['DT', 'SPOT', 'EXCAVATOR'].contains(e.key)) continue;
      morceaux.add('${e.value} ${_nomRole(e.key)}');
    }
    return 'Wi-Fi : ${morceaux.join(', ')} connecte(s)';
  }

  /// Libelle court d'un role recu au handshake.
  static String _nomRole(String role) {
    final String r = role.trim().toUpperCase();
    if (r.contains('SPOT')) return r == 'SPOT' ? 'spotter' : 'spotters';
    if (r == 'DT' || r.contains('TAB2')) return 'DT';
    if (r.contains('EXCAVATOR') || r.contains('TAB3')) return 'excavatrice';
    return 'client';
  }

  /// Vrai si la tablette courante est l'excavatrice (elle sert le reseau).
  static bool _localEstExcavatrice(Session session) {
    final String role = (session.profile?.roleCdc ?? '').trim().toUpperCase();
    return BaseLocale.estTab3(role) || role == 'EXCAVATOR';
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

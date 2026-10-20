import 'dart:async';

import 'package:flutter/material.dart';

import '../state/etat_couche.dart';
import '../state/session.dart';
import '../theme/app_theme.dart';
import '../theme/responsive.dart';

/// Boite commune des voyants d'etat (4G, GPS, BLE, Wi-Fi).
///
/// Elle prend la place qu'on lui donne et non une taille fixe : un badge pose
/// dans une barre etroite se reduit avec elle, au lieu d'imposer sa taille et
/// de faire deborder la ligne. Sa hauteur reste bornee par [taille] — jamais
/// plus haute que la taille de reference — et son contenu est mis a l'echelle
/// du cadre par un `FittedBox`, donc rien n'est jamais rogne ni coupe.
class _BoiteBadge extends StatelessWidget {
  const _BoiteBadge({
    required this.taille,
    required this.couleur,
    required this.epaisseur,
    required this.enfant,
    this.remplir = false,
  });

  /// Taille de reference du badge (largeur puis hauteur maximum).
  final Size taille;
  final Color couleur;
  final double epaisseur;
  final Widget enfant;

  /// Vrai pour les badges poses seuls dans une colonne sans largeur imposee
  /// (ecran excavator) : la largeur de reference est alors utilisee telle
  /// quelle, comme une taille demandee et non comme un maximum.
  final bool remplir;

  @override
  Widget build(BuildContext context) {
    final Widget contenu = Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: couleur, width: epaisseur),
      ),
      padding: const EdgeInsets.all(2),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: SizedBox(
          width: taille.width,
          height: taille.height,
          child: enfant,
        ),
      ),
    );

    if (remplir) {
      return SizedBox(width: taille.width, height: taille.height, child: contenu);
    }
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: taille.width,
        maxHeight: taille.height,
      ),
      child: contenu,
    );
  }
}

/// Clignotement d'alerte : quand [Session.alerteActive], le widget enfant
/// clignote (opacite alternée 1 / 0.25, période 600 ms) pour attirer l'œil.
/// Hors alerte, il est rendu tel quel sans aucun coût d'animation.
class Clignotant extends StatefulWidget {
  const Clignotant({super.key, required this.session, required this.child});

  final Session session;
  final Widget child;

  @override
  State<Clignotant> createState() => _ClignotantState();
}

class _ClignotantState extends State<Clignotant>
    with SingleTickerProviderStateMixin {
  AnimationController? _controleur;

  void _ajuster() {
    final bool doit = widget.session.alerteActive;
    if (doit && _controleur == null) {
      _controleur = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 600),
        value: 0,
      )..repeat(reverse: true);
    } else if (!doit && _controleur != null) {
      _controleur!.dispose();
      _controleur = null;
    }
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    widget.session.addListener(_ajuster);
    if (widget.session.alerteActive) _ajuster();
  }

  @override
  void didUpdateWidget(covariant Clignotant old) {
    super.didUpdateWidget(old);
    if (old.session != widget.session) {
      old.session.removeListener(_ajuster);
      widget.session.addListener(_ajuster);
    }
  }

  @override
  void dispose() {
    widget.session.removeListener(_ajuster);
    _controleur?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AnimationController? c = _controleur;
    if (c == null) return widget.child;
    return FadeTransition(
      opacity: Tween<double>(begin: 1.0, end: 0.25).animate(
        CurvedAnimation(parent: c, curve: Curves.easeInOut),
      ),
      child: widget.child,
    );
  }
}

/// Boite d'etat du signal : connexion au point d'acces Master (Wi-Fi Direct).
class WifiStatusBadge extends StatelessWidget {
  const WifiStatusBadge({super.key, required this.etat});

  /// Etat de la couche (CDC §20) : rouge / orange / vert.
  final EtatCouche etat;

  @override
  Widget build(BuildContext context) {
    final MiseEnPage mise = MiseEnPage.depuis(context);
    final double k = mise.k;
    final Color color = etat.couleur;
    return Container(
      width: mise.tailleBadge.width,
      height: mise.tailleBadge.height,
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: AppColors.border, width: (2 * k).clamp(1.0, 2.0)),
      ),
      padding: EdgeInsets.symmetric(vertical: (8 * k).clamp(4.0, 8.0)),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.wifi, size: (38 * k).clamp(18.0, 38.0), color: color),
          SizedBox(height: (8 * k).clamp(3.0, 8.0)),
          Text(
            etat.libelle,
            style: TextStyle(
              fontFamily: kSerif,
              fontSize: (13 * k).clamp(9.0, 13.0),
              color: color,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

/// Boite d'etat du GPS externe (recepteur USB-C, §5).
///
/// Voyage avec la meme mise en forme que les autres voyants : icone
/// satellite coloree selon l'etat (rouge = service arrete, orange = en
/// acquisition, vert = position recue), libelle d'etat dessous.
class GpsStatusBadge extends StatelessWidget {
  const GpsStatusBadge({super.key, required this.etat, this.remplir = false});

  /// Etat du lien GPS : « vert » = une position est disponible.
  final EtatCouche etat;

  /// Vrai quand le badge est pose dans une colonne sans largeur imposee
  /// (ecran excavator) : il prend alors sa largeur de reference au lieu de
  /// s'en servir comme maximum.
  final bool remplir;

  @override
  Widget build(BuildContext context) {
    final MiseEnPage mise = MiseEnPage.depuis(context);
    final double k = mise.k;
    final Color color = etat.couleur;
    return _BoiteBadge(
      taille: mise.tailleBadge,
      couleur: color,
      epaisseur: (3 * k).clamp(1.5, 3.0),
      enfant: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.gps_fixed,
              size: (30 * k).clamp(15.0, 30.0), color: color),
          SizedBox(height: (4 * k).clamp(2.0, 4.0)),
          Text(
            etat.libelle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: kSerif,
              fontSize: (13 * k).clamp(9.0, 13.0),
              color: color,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
      remplir: remplir,
    );
  }
}

/// Boite d'etat du reseau GSM (4G) - reservee au profil DT.
class GsmStatusBadge extends StatelessWidget {
  const GsmStatusBadge({super.key, required this.etat, this.remplir = false});

  /// Etat du lien avec le serveur : « vert » = le serveur a repondu.
  final EtatCouche etat;

  /// Vrai quand le badge est pose dans une colonne sans largeur imposee : il
  /// prend alors sa largeur de reference au lieu de s'en servir comme maximum.
  final bool remplir;

  @override
  Widget build(BuildContext context) {
    final MiseEnPage mise = MiseEnPage.depuis(context);
    final double k = mise.k;
    final Color color = etat.couleur;
    // Le contenu est mis a l'echelle du cadre : la boite peut se reduire (ecran
    // etroit), le 4G et son libelle suivent au lieu de deborder de 40 px.
    return _BoiteBadge(
      taille: mise.tailleBadge,
      couleur: color,
      epaisseur: (3 * k).clamp(1.5, 3.0),
      enfant: FittedBox(
        fit: BoxFit.scaleDown,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '4G',
              style: TextStyle(
                fontFamily: kSerif,
                fontSize: (38 * k).clamp(18.0, 38.0),
                height: 1,
                fontWeight: FontWeight.w900,
                color: color,
              ),
            ),
            SizedBox(height: (6 * k).clamp(2.0, 6.0)),
            Text(
              etat.libelle,
              style: TextStyle(
                fontFamily: kSerif,
                fontSize: (13 * k).clamp(9.0, 13.0),
                color: color,
              ),
            ),
          ],
        ),
      ),
      remplir: remplir,
    );
  }
}

/// Boite d'etat de la couche BLE (CDC §20.2/§20.3).
///
/// Cote DT elle affiche le nombre d'excavatrices (TAB 3) connectées ; cote
/// excavatrice elle signale seulement l'etat du lien vers le DT (TAB 2). Les
/// seuils RSSI sont ceux du
/// CDC §8 (lecture seule ici : la decision d'entree/sortie reste au
/// [ControleurProximite], pas a l'ecran).
class BleStatusBadge extends StatelessWidget {
  const BleStatusBadge({
    super.key,
    required this.etat,
    this.nombreClients,
    this.remplir = false,
  });

  /// Etat de la couche : rouge = pas demarree, orange = en decouverte,
  /// vert = au moins un lien authentifie.
  final EtatCouche etat;

  /// Nombre d'excavatrices connectées (cote DT uniquement, null sinon).
  final int? nombreClients;

  /// Vrai quand le badge est pose dans une colonne sans largeur imposee : il
  /// prend alors sa largeur de reference au lieu de s'en servir comme maximum.
  final bool remplir;

  /// Libelle affiché quand la couche est montee : compteur cote passerelle,
  /// cible cote client.
  String get _libelleConnecte {
    if (etat != EtatCouche.connecte) return etat.libelle;
    if (nombreClients == null) return 'DT';
    return '$nombreClients Excavator';
  }

  @override
  Widget build(BuildContext context) {
    final MiseEnPage mise = MiseEnPage.depuis(context);
    final double k = mise.k;
    final Color color = etat.couleur;
    return _BoiteBadge(
      taille: mise.tailleBadge,
      couleur: color,
      epaisseur: (3 * k).clamp(1.5, 3.0),
      enfant: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.bluetooth,
              size: (30 * k).clamp(15.0, 30.0), color: color),
          SizedBox(height: (4 * k).clamp(2.0, 4.0)),
          Text(
            _libelleConnecte,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: kSerif,
              fontSize: (13 * k).clamp(9.0, 13.0),
              color: color,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
      remplir: remplir,
    );
  }
}

/// Boite d'etat de la couche Wi-Fi P2P DT <-> spotter (REQ-007/008).
///
/// Distincte de [WifiStatusBadge] : celle-la montre l'etat du reseau local
/// (point d'acces Master), celle-ci l'etat de la couche applicative TCP
/// (serveur DT ou client spotter) posee par-dessus. Meme glyph [Icons.wifi]
/// que l'autre voyant wifi : c'est le libelle (compteur Spotter) qui
/// distingue les deux.
class WifiP2pStatusBadge extends StatelessWidget {
  const WifiP2pStatusBadge({
    super.key,
    required this.etat,
    this.nombreClients,
    this.remplir = false,
  });

  /// Etat de la couche (CDC §20) : rouge / orange / vert.
  final EtatCouche etat;

  /// Nombre de spotters connectés (cote DT uniquement).
  final int? nombreClients;

  /// Vrai quand le badge est pose dans une colonne sans largeur imposee : il
  /// prend alors sa largeur de reference au lieu de s'en servir comme maximum.
  final bool remplir;

  String get _libelleConnecte {
    if (etat != EtatCouche.connecte) return etat.libelle;
    if (nombreClients == null) return 'DT';
    return '$nombreClients Spotter';
  }

  @override
  Widget build(BuildContext context) {
    final MiseEnPage mise = MiseEnPage.depuis(context);
    final double k = mise.k;
    final Color color = etat.couleur;
    return _BoiteBadge(
      taille: mise.tailleBadge,
      // Meme couleur que l'interieur : le cadre suit l'etat (rouge/orange/vert)
      // au lieu d'un gris fixe, pour se lire comme les autres voyants.
      couleur: color,
      epaisseur: (2 * k).clamp(1.0, 2.0),
      // Le contenu se comprime avec la boite : sur un voyant de 22 px de
      // haut (telephone en paysage), l'icone a sa taille pleine debordait de
      // 3 px. Le `FittedBox` reduit l'ensemble au lieu de rogner.
      enfant: FittedBox(
        fit: BoxFit.scaleDown,
        child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.wifi, size: (46 * k).clamp(20.0, 46.0), color: color),
          SizedBox(height: (4 * k).clamp(2.0, 4.0)),
          Text(
            _libelleConnecte,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: kSerif,
              fontSize: (13 * k).clamp(9.0, 13.0),
              color: color,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
        ),
      ),
      remplir: remplir,
    );
  }
}

/// Carre sombre (bas de gauche) : echange de donnees avec le serveur local.
///
/// La fleche s'anime (rotation continue) tant que la session transmet
/// effectivement des donnees au DT — Wi-Fi ([Session.envoiWifiActif]) ou
/// BLE ([Session.envoiBleActif]).
class DataExchangeButton extends StatelessWidget {
  const DataExchangeButton({super.key, this.onPressed, this.session});

  final VoidCallback? onPressed;

  /// Session optionnelle : fournie, l'icone s'anime pendant un envoi.
  final Session? session;

  @override
  Widget build(BuildContext context) {
    final double cote = MiseEnPage.depuis(context).hauteurTicker;
    final Session? session = this.session;
    final bool enEnvoi = session != null &&
        (session.envoiWifiActif || session.envoiBleActif);
    final Widget icone = enEnvoi
        ? const _FlecheAnimee()
        : Icon(Icons.import_export, color: Colors.white, size: cote * 0.48);
    return Material(
      color: AppColors.darkSquare,
      child: InkWell(
        onTap: onPressed,
        child: SizedBox(
          width: cote,
          height: cote,
          child: icone,
        ),
      ),
    );
  }
}

/// Fleche d'echange en rotation continue : marque visuellement qu'un envoi
/// est en cours (REQ-007), sans casser la lisibilite de l'icone.
class _FlecheAnimee extends StatefulWidget {
  const _FlecheAnimee();

  @override
  State<_FlecheAnimee> createState() => _FlecheAnimeeState();
}

class _FlecheAnimeeState extends State<_FlecheAnimee>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controleur = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat();

  @override
  void dispose() {
    _controleur.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final double cote = MiseEnPage.depuis(context).hauteurTicker;
    return AnimatedBuilder(
      animation: _controleur,
      builder: (context, child) => Transform.rotate(
        angle: _controleur.value * 2 * 3.14159,
        child: child,
      ),
      child: Icon(Icons.import_export, color: Colors.white, size: cote * 0.48),
    );
  }
}

/// Carre blanc (bas de droite) : icone d'echange de donnees avec le serveur
/// local apres connexion au point d'accès.
///
/// Pendant une passe de synchronisation serveur ([Session.synchroActive],
/// déclenchée dès que la 4G est disponible), le nuage s'anime : rotation
/// douce du nuage + flèche de téléchargement. Hors synchro, il retrouve
/// son etat statique (nuage vert « done » ou nuage coupé).
class SyncCloudIcon extends StatefulWidget {
  const SyncCloudIcon({super.key, required this.session});

  final Session session;

  @override
  State<SyncCloudIcon> createState() => _SyncCloudIconState();
}

class _SyncCloudIconState extends State<SyncCloudIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _rotation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );

  @override
  void initState() {
    super.initState();
    widget.session.addListener(_suivre);
    // Cree le controleur des maintenant : `_rotation` n'est lu dans [build]
    // que si une synchro tourne, donc sans notification il ne serait cree
    // qu'au moment du dispose — ou l'element est deja desactive et la
    // recherche d'ancetre plante (« Looking up a deactivated widget's
    // ancestor is unsafe »). `stop()` sur un controleur neuf ne change rien.
    _rotation.stop();
  }

  @override
  void didUpdateWidget(covariant SyncCloudIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session != widget.session) {
      oldWidget.session.removeListener(_suivre);
      widget.session.addListener(_suivre);
    }
  }

  void _suivre() {
    if (widget.session.synchroActive) {
      if (!_rotation.isAnimating) _rotation.repeat();
    } else if (_rotation.isAnimating) {
      _rotation.stop();
      _rotation.value = 0;
    }
    setState(() {});
  }

  @override
  void dispose() {
    widget.session.removeListener(_suivre);
    _rotation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final double cote = MiseEnPage.depuis(context).hauteurTicker;
    final EtatCouche etat = widget.session.etatWifiDevice;
    final bool enSynchro = widget.session.synchroActive;
    final Icon icone;
    if (enSynchro) {
      icone = Icon(
        Icons.backup_outlined,
        size: cote * 0.55,
        color: AppColors.orange,
      );
    } else {
      icone = Icon(
        etat == EtatCouche.connecte
            ? Icons.cloud_done_outlined
            : Icons.cloud_off_outlined,
        size: cote * 0.55,
        color: etat == EtatCouche.connecte
            ? AppColors.green
            : AppColors.darkSquare,
      );
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => unawaited(widget.session.synchroniserManuellement()),
      child: Container(
        width: cote,
        height: cote,
        color: Colors.white,
        alignment: Alignment.center,
        child: enSynchro
            ? RotationTransition(turns: _rotation, child: icone)
            : icone,
      ),
    );
  }
}

/// Boite d'etat du **point d'acces** porte par l'excavatrice.
///
/// Distincte de [WifiP2pStatusBadge] (qui compte les clients branches a la
/// couche TCP) : ici on montre le **reseau lui-meme**. C'est le voyant qui dit
/// a l'operateur « les autres tablettes peuvent me joindre », et sans lui un
/// spotter cherche une excavatrice qui n'emet rien.
///
/// Rouge = couche arretee ou demarrage refuse, orange = demarrage en cours,
/// vert = reseau ouvert. Le SSID reel est affiche des que le point d'acces
/// existe : c'est celui qu'Android a attribue, pas celui demande.
class PointAccesStatusBadge extends StatelessWidget {
  const PointAccesStatusBadge({
    super.key,
    required this.etat,
    this.ssid = '',
    this.remplir = false,
  });

  final EtatCouche etat;

  /// SSID reellement attribue par Android (vide tant que rien n'est ouvert).
  final String ssid;

  final bool remplir;

  String get _libelle {
    if (etat != EtatCouche.connecte) return etat.libelle;
    // Le cadre est etroit : seuls les caracteres qui distinguent deux
    // excavatrices sont utiles. `AndroidShare_6247` -> `_6247`.
    if (ssid.isEmpty) return 'AP';
    final String court = ssid.length <= 5
        ? ssid
        : '…${ssid.substring(ssid.length - 4)}';
    return court;
  }

  @override
  Widget build(BuildContext context) {
    final MiseEnPage mise = MiseEnPage.depuis(context);
    final double k = mise.k;
    final Color color = etat.couleur;
    return _BoiteBadge(
      taille: mise.tailleBadge,
      couleur: color,
      epaisseur: (2 * k).clamp(1.0, 2.0),
      remplir: remplir,
      enfant: FittedBox(
        fit: BoxFit.scaleDown,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.wifi_tethering,
                size: (38 * k).clamp(18.0, 38.0), color: color),
            SizedBox(height: (2 * k).clamp(1.0, 2.0)),
            Text(
              _libelle,
              maxLines: 1,
              softWrap: false,
              style: TextStyle(
                fontFamily: kSerif,
                fontSize: (12 * k).clamp(8.0, 12.0),
                color: color,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Session de la perle (godet) pour un DT donne — profil excavator (§2.3).
///
/// Pendant qu'un DT est dans le rayon de connexion de l'excavatrice, chaque
/// position GNSS de la perle est :
/// 1. projetee dans le repere du bloc (`Xbloc`, `Ybloc`, `Zbloc`) ;
/// 2. envoyee au DT (position brute) ;
/// 3. accumulatee pour la moyenne de la session.
///
/// A la **sortie de zone** (« decollage »), la moyenne courante est gelee
/// ([MoyennePerle]) puis l'accumulateur est **remis a zero**. Le prochain
/// passage du meme DT est donc une **nouvelle session**, independante : c'est
/// la regle retenue au terrain.
///
/// Cette classe est de la pure arithmetique : elle ne connait ni le BLE ni la
/// base. La session applicative ([Session]) l'alimente a chaque mesure et
/// decide quand gelee/envoyer.
class SessionPerle {
  SessionPerle({required this.dt});

  /// Identifiant du DT avec qui la session est ouverte (ex. `TAB2-DT13`).
  final String dt;

  int _sommeX = 0;
  int _sommeY = 0;
  int _sommeZ = 0;
  int _nombre = 0;

  /// Nombre de positions accumulees depuis le debut de la session.
  int get nombre => _nombre;

  /// Vrai tant qu'aucune position n'a ete accumulee.
  bool get vide => _nombre == 0;

  /// Ajoute une position de perle a l'accumulateur.
  void ajouter({
    required int xbloc,
    required int ybloc,
    required int zbloc,
  }) {
    _sommeX += xbloc;
    _sommeY += ybloc;
    _sommeZ += zbloc;
    _nombre++;
  }

  /// Moyenne courante, ou `null` si la session est vide.
  ///
  /// Arrondie a l'entier : les coordonnees de bloc sont entieres (§2.3), la
  /// moyenne suit la meme convention que le protocole.
  MoyennePerle? get moyenne {
    if (_nombre == 0) return null;
    return MoyennePerle(
      xmoy: (_sommeX / _nombre).round(),
      ymoy: (_sommeY / _nombre).round(),
      zmoy: (_sommeZ / _nombre).round(),
      nombre: _nombre,
      dt: dt,
    );
  }

  /// Gele la moyenne courante et **remet la session a zero**.
  ///
  /// Appelee a la sortie de zone du DT : la moyenne rendue doit etre envoyee
  /// (au DT, qui la transmettra au serveur), puis la session repart vierge
  /// pour le prochain passage. Rend `null` si rien n'a ete accumule (un DT
  /// qui n'a jamais rien envoye ne doit pas produire de moyenne vide).
  MoyennePerle? gelerEtReinitialiser() {
    final MoyennePerle? resultat = moyenne;
    _sommeX = 0;
    _sommeY = 0;
    _sommeZ = 0;
    _nombre = 0;
    return resultat;
  }
}

/// Moyenne des positions de la perle sur une session de connexion (§2.3).
///
/// C'est cette valeur qui part vers le serveur : elle lui sert a definir la
/// Destination et la Dumping Area.
class MoyennePerle {
  const MoyennePerle({
    required this.xmoy,
    required this.ymoy,
    required this.zmoy,
    required this.nombre,
    required this.dt,
  });

  final int xmoy;
  final int ymoy;
  final int zmoy;

  /// Nombre de positions qui ont produit cette moyenne.
  final int nombre;

  /// DT de la session (ex. `TAB2-DT13`).
  final String dt;

  @override
  String toString() =>
      'MoyennePerle(x=$xmoy, y=$ymoy, z=$zmoy, n=$nombre, dt=$dt)';
}

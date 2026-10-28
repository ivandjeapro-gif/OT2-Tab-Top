package com.oretracking.ore_tracking

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * Pont entre Dart et le gestionnaire Wi-Fi Direct.
 *
 * Le hotspot Wi-Fi n'est **pas** activable en Dart : Android 13+ reserve
 * `startLocalOnlyHotspot()` aux applications systeme. Le seul moyen d'etre
 * automatiquement point d'acces est `WifiP2pManager` (Wi-Fi Direct), qui vit
 * cote natif — d'ou ce canal.
 *
 * Canal : `ore_tracking/wifi_direct`
 * - `demarrer` -> cree le groupe, force Group Owner ;
 * - `arreter` -> ferme le groupe ;
 * - `etat` -> etat courant (disponible, groupe forme, adresse) ;
 * - `clients` -> liste des DT connectes.
 *
 * Toute methode rend une enveloppe `{ok: bool, erreur: String?}` : aucune
 * exception ne traverse la frontiere Dart, la couche applicative journalise
 * l'echec et continue.
 */
class MainActivity : FlutterActivity() {

    private val canal = "ore_tracking/wifi_direct"
    private val codePermissionWifi = 4210
    private companion object { const val TAG = "OreMainActivity" }

    private var wifiDirect: WifiDirectManager? = null

    /// Client BLE natif : autoConnect + persistance du pairing.
    private var bleCentral: BleCentralManager? = null
    private var hotspot: HotspotManager? = null
    private var wifiClient: WifiClientManager? = null
    private var routeReseau: RouteReseau? = null
    private var partage: PartageConnexion? = null
    private var pendingResult: MethodChannel.Result? = null

    /**
     * Accepte automatiquement les demandes de pairage Bluetooth.
     *
     * POURQUOI : l'excavatrice diffuse son service GATT, et le DT tente de
     * s'y connecter. Android exige alors un PAIREMENT et affiche une
     * notification « Associer l'appareil a ORE-EXC-001 ? » qui reste
     * SUSPENDUE tant que personne ne repond — la connexion n'aboutit jamais
     * et l'excavatrice affiche « Aucun DT connecte » (observe le 22/10).
     *
     * Notre protocole fait sa propre authentification (handshake + ids
     * autorises), donc le pairage systeme n'apporte aucune securite
     * supplementaire : on l'accepte sans intervention de l'operateur. Le code
     * PIN est celui du groupe (`oretracking` n'a pas de PIN ; on utilise
     * 0000, la valeur acceptee par Android pour un Just Works automatique).
     */
    private val recepteurPairage = object : android.content.BroadcastReceiver() {
        override fun onReceive(contexte: android.content.Context, intent: android.content.Intent) {
            val action = intent.action ?: return
            // `ACTION_PAIRING_CANCEL` n'est pas exposee publiquement par le
            // SDK : on la compare par son nom de contrat, identique a celui
            // que diffuse Android.
            val pairage = android.bluetooth.BluetoothDevice.ACTION_PAIRING_REQUEST
            val annulation = "android.bluetooth.device.action.PAIRING_CANCEL"
            if (action != pairage && action != annulation) return
            val appareil = if (android.os.Build.VERSION.SDK_INT >= 33) {
                intent.getParcelableExtra(
                    android.bluetooth.BluetoothDevice.EXTRA_DEVICE,
                    android.bluetooth.BluetoothDevice::class.java,
                )
            } else {
                @Suppress("DEPRECATION")
                intent.getParcelableExtra(android.bluetooth.BluetoothDevice.EXTRA_DEVICE)
            } ?: return
            if (action == annulation) {
                Log.w(TAG, "Pairage annule pour ${appareil.address}")
                return
            }
            try {
                // PIN 0000 + acceptation immediate : c'est ce qui debloque la
                // connexion GATT cote DT.
                appareil.setPairingConfirmation(true)
                Log.i(TAG, "Pairage accepte automatiquement pour ${appareil.address}")
            } catch (e: Exception) {
                Log.w(TAG, "Pairage auto refuse : ${e.message}")
            }
            // Empeche Android d'afficher sa notification (elle consommerait
            // le broadcast et laisserait la demande suspendue).
            try {
                abortBroadcast()
            } catch (_: Exception) {
                // Broadcast non ordonne : rien a annuler, sans consequence.
            }
        }
    }

    private fun enregistrerRecepteurPairage() {
        val filtre = android.content.IntentFilter().apply {
            addAction(android.bluetooth.BluetoothDevice.ACTION_PAIRING_REQUEST)
            addAction("android.bluetooth.device.action.PAIRING_CANCEL")
            priority = 1000
        }
        try {
            if (android.os.Build.VERSION.SDK_INT >= 33) {
                registerReceiver(recepteurPairage, filtre, android.content.Context.RECEIVER_EXPORTED)
            } else {
                @Suppress("UnspecifiedRegisterReceiverFlag")
                registerReceiver(recepteurPairage, filtre)
            }
            Log.i(TAG, "Recepteur de pairage BLE enregistre")
        } catch (e: Exception) {
            Log.w(TAG, "Recepteur de pairage non enregistre : ${e.message}")
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        wifiDirect = WifiDirectManager(applicationContext)
        hotspot = HotspotManager(applicationContext)
        wifiClient = WifiClientManager(applicationContext)
        routeReseau = RouteReseau(applicationContext)
        partage = PartageConnexion(applicationContext)
        // Pairage BLE accepte automatiquement : sans lui, la demande
        // Android reste suspendue et le DT ne se connecte jamais.
        enregistrerRecepteurPairage()

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, canal)
            .setMethodCallHandler { appel, resultat ->
                val gestionnaire = wifiDirect
                if (gestionnaire == null) {
                    resultat.success(mapOf("ok" to false, "erreur" to "gestionnaire absent"))
                    return@setMethodCallHandler
                }
                when (appel.method) {
                    // Point d'acces local : voie par defaut de l'excavatrice.
                    // `LocalOnlyHotspot` est une API du framework (Android 8+) :
                    // le systeme choisit le reseau et rend SSID + mot de passe,
                    // sans les contraintes ni les echecs de Wi-Fi Direct.
                    "demarrer", "demarrer_hotspot" -> {
                        val nom = appel.argument<String>("nom") ?: "ORE-EXC-001"
                        val mdp = appel.argument<String>("motDePasse")
                        val h = hotspot
                        if (appel.method == "demarrer_hotspot" || (h != null && h.estDisponible())) {
                            if (h == null) {
                                resultat.success(mapOf("ok" to false, "erreur" to "hotspot indisponible"))
                                return@setMethodCallHandler
                            }
                            if (!aPermissionWifi()) {
                                pendingResult = resultat
                                demanderPermissionWifi()
                                return@setMethodCallHandler
                            }
                            h.demarrer(
                                nom,
                                mdp ?: HotspotManager.MOT_DE_PASSE_DEFAUT,
                            ) { ok, erreur, ssid, mdpReseau, adresse ->
                                runOnUiThread {
                                    resultat.success(
                                        mapOf(
                                            "ok" to ok,
                                            "erreur" to erreur,
                                            "ssid" to ssid,
                                            // Le mot de passe REEL du reseau, pas celui
                                            // demande : en repli, Android en genere un autre.
                                            "motDePasse" to (mdpReseau ?: mdp),
                                            "adresse" to adresse,
                                            "type" to "hotspot",
                                        )
                                    )
                                }
                            }
                            return@setMethodCallHandler
                        }
                        // Repli : Wi-Fi Direct (Android ancien ou hotspot refuse).
                        if (!aPermissionWifi()) {
                            pendingResult = resultat
                            demanderPermissionWifi()
                            return@setMethodCallHandler
                        }
                        gestionnaire.demarrerGroupe(nom) { ok, erreur ->
                            runOnUiThread {
                                resultat.success(
                                    mapOf("ok" to ok, "erreur" to erreur, "type" to "wifi_direct")
                                )
                            }
                        }
                    }
                    "arreter" -> {
                        // On ferme les deux : un repli a pu laisser un groupe
                        // Wi-Fi Direct ouvert pendant que le hotspot tournait.
                        hotspot?.arreter { _, _ -> }
                        gestionnaire.arreterGroupe { ok, erreur ->
                            runOnUiThread {
                                resultat.success(mapOf("ok" to ok, "erreur" to erreur))
                            }
                        }
                    }
                    // --- role client (DT, spotter) ---
                    "decouvrir" -> {
                        if (!aPermissionWifi()) {
                            pendingResult = resultat
                            demanderPermissionWifi()
                            return@setMethodCallHandler
                        }
                        gestionnaire.decouvrirGroupes { ok, erreur, pairs ->
                            runOnUiThread {
                                resultat.success(
                                    mapOf("ok" to ok, "erreur" to erreur, "pairs" to pairs)
                                )
                            }
                        }
                    }
                    "connecter" -> {
                        val nom = appel.argument<String>("nom") ?: "ORE-EXC"
                        if (!aPermissionWifi()) {
                            pendingResult = resultat
                            demanderPermissionWifi()
                            return@setMethodCallHandler
                        }
                        gestionnaire.connecterGroupe(nom) { ok, erreur ->
                            runOnUiThread {
                                resultat.success(mapOf("ok" to ok, "erreur" to erreur))
                            }
                        }
                    }
                    "oublier" -> gestionnaire.oublierGroupe { ok, erreur ->
                        runOnUiThread {
                            resultat.success(mapOf("ok" to ok, "erreur" to erreur))
                        }
                    }
                    // --- role client : rejoindre le point d'acces annonce ---
                    "rejoindre_reseau" -> {
                        val ssid = appel.argument<String>("ssid") ?: ""
                        val mdp = appel.argument<String>("motDePasse") ?: ""
                        val c = wifiClient
                        if (c == null) {
                            resultat.success(
                                mapOf("ok" to false, "erreur" to "client Wi-Fi absent")
                            )
                            return@setMethodCallHandler
                        }
                        // SUGGESTION DEPOSEE AVANT TOUT : `requestNetwork`
                        // n'est qu'un coup de pouce immediat ; c'est la
                        // suggestion memorisee qui fait que la tablette
                        // rejoint d'elle-meme le hotspot aux demarrages
                        // suivants. Elle etait conditionnee a `ok` du
                        // requestNetwork, qui echoue des que l'ecran est
                        // verrouille — Android affichait donc « se connecter »
                        // a chaque fois (observe 22/10).
                        c.memoriser(ssid, mdp)
                        c.connecter(ssid, mdp) { ok, erreur ->
                            runOnUiThread {
                                resultat.success(
                                    mapOf(
                                        "ok" to ok,
                                        "erreur" to erreur,
                                        "adresseLocale" to c.adresseLocale(),
                                    )
                                )
                            }
                        }
                    }
                    // --- route reseau : garder la 4G pour le serveur ---
                    // Des que la tablette rejoint le point d'acces local (sans
                    // Internet), Android y envoie TOUT le trafic : les appels
                    // vers Apps Script echouent alors que la 4G est presente.
                    "forcer_cellulaire" -> resultat.success(
                        mapOf("ok" to (routeReseau?.forcerCellulaire() == true))
                    )
                    "liberer_route" -> {
                        routeReseau?.liberer()
                        resultat.success(mapOf("ok" to true))
                    }
                    // --- surveillance du point d'acces ---
                    // `etat` seul ne suffit pas : on demande explicitement si
                    // l'interface emet, et on relance la reservation si elle a
                    // disparu sans que l'app l'ait su.
                    // --- partage de connexion systeme (excavatrice) ---
                    // `LocalOnlyHotspot` filtre le trafic entrant de l'hote :
                    // les clients ne peuvent pas joindre le serveur TCP.
                    // Le partage systeme, lui, les laisse communiquer.
                    "demarrer_partage" -> {
                        val p = partage
                        if (p == null) {
                            resultat.success(mapOf("ok" to false, "erreur" to "service absent"))
                            return@setMethodCallHandler
                        }
                        p.demarrer { ok, erreur ->
                            runOnUiThread {
                                resultat.success(
                                    mapOf(
                                        "ok" to ok,
                                        "erreur" to erreur,
                                        "ssid" to PartageConnexion.SSID,
                                        "motDePasse" to PartageConnexion.MOT_DE_PASSE,
                                        "disponible" to p.estDisponible(),
                                    )
                                )
                            }
                        }
                    }
                    "etat_partage" -> resultat.success(partage?.etat() ?: mapOf<String, Any?>())
                    // --- partage actif par l'OPERATEUR (refonte 21/10) ---
                    // Detection du partage deja active dans les Reglages :
                    // interface ap0 + config reelle. C'est cette voie qui
                    // rend le TCP joignable, la seule qui marche sur Android 13+.
                    "partage_actif" -> resultat.success(
                        mapOf(
                            "actif" to (partage?.partageActif() == true),
                            "adresse" to partage?.adressePartage(),
                            // Config reelle (SSID + mot de passe) pour
                            // provisionner le DT via BLE.
                            "config" to partage?.configPartage(),
                        )
                    )
                    "ouvrir_reglages_partage" -> {
                        partage?.ouvrirReglagesPartage()
                        resultat.success(mapOf("ok" to true))
                    }
                    "verifier_hotspot" -> {
                        // Surveillance SANS relance (refonte 21/10) : ouvrir
                        // un LocalOnlyHotspot quand le partage systeme tourne
                        // le faisait tuer par Android (badge vert 3 s puis
                        // orange, observe par l'operateur). L'app ne fait que
                        // constater l'interface `ap*` : si le partage a ete
                        // active par l'operateur, il est utilise tel quel ;
                        // sinon l'operateur l'active dans les Reglages (tap
                        // sur le badge -> TetherSettings).
                        val partageEnCours = partage?.partageActif() == true
                        val hotspotLocal = hotspot?.emet() == true
                        resultat.success(
                            mapOf(
                                "ok" to (partageEnCours || hotspotLocal),
                                "emet" to (partageEnCours || hotspotLocal),
                            )
                        )
                    }
                    "etat_cellulaire" -> {
                        // DEUX mesures distinctes, et c'est le coeur du sujet :
                        //
                        // - `present` : la radio cellulaire est-elle DECLAREE
                        //   et validee par le systeme ? Lecture instantanee des
                        //   drapeaux, fiable quand le systeme est a jour.
                        // - `actif` : une socket joint-elle vraiment Internet
                        //   par la 4G ? La sonde coute son delai complet (4 s)
                        //   quand la 4G est coupee.
                        //
                        // Les confondre etait l'erreur : avec 3 s de cadence,
                        // une sonde qui dure 4 s n'aboutissait jamais avant la
                        // suivante et le badge restait fige sur une valeur
                        // ancienne. On sert donc d'abord les drapeaux (rapides,
                        // et justes sur une coupure franche), et on ne lance la
                        // sonde active que si les drapeaux annoncent une 4G
                        // presente — cas ou il faut distinguer « presente mais
                        // morte » (ccmni1 sans adresse).
                        val r = routeReseau
                        if (r == null) {
                            resultat.success(mapOf("actif" to false, "present" to false))
                            return@setMethodCallHandler
                        }
                        Thread {
                            val declare = r.cellulaireSousJacente()
                            // 4G absente des drapeaux : inutile de sonder, la
                            // reponse est certaine et immediate.
                            val ok = if (declare) r.sondeCellulaire(delaiMs = 1500) else false
                            Log.i("OreRoute", "SONDE 4G declare=$declare actif=$ok")
                            runOnUiThread {
                                resultat.success(
                                    mapOf("actif" to ok, "present" to ok)
                                )
                            }
                        }.start()
                    }
                    "adresse_locale" -> resultat.success(
                        mapOf(
                            "ok" to true,
                            "adresseLocal" to wifiClient?.adresseLocale(),
                        )
                    )
                    "etat" -> {
                        val etatHotspot = hotspot?.etat() ?: emptyMap()
                        resultat.success(
                            mapOf("ok" to true) + gestionnaire.etat() + etatHotspot +
                                mapOf("typeHotspot" to (hotspot?.estDisponible() == true))
                        )
                    }
                    "clients" -> gestionnaire.clients { noms ->
                        runOnUiThread {
                            resultat.success(mapOf("ok" to true, "clients" to noms))
                        }
                    }
                    else -> resultat.notImplemented()
                }
            }

        // ─── CLIENT BLE NATIF : autoConnect + persistance du pairing ─────
        //
        // `flutter_reactive_ble` ne sait pas faire `connectGatt(…, true, …)` :
        // Android ne garde alors aucune demande en attente, et la reconnexion
        // depend d'un scan applicatif. Ce canal delegue la surveillance au
        // SYSTEME, qui reconnecte des que l'appareil redevient visible.
        bleCentral = BleCentralManager(applicationContext)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "oret/ble_central")
            .setMethodCallHandler { appel, resultat ->
                val g = bleCentral
                if (g == null) {
                    resultat.success(mapOf("ok" to false, "erreur" to "gestionnaire absent"))
                    return@setMethodCallHandler
                }
                when (appel.method) {
                    "etat" -> resultat.success(g.etatPile())
                    "connecter_direct" -> g.connecterDirect(resultat)
                    "connecter" -> {
                        val adresse = appel.argument<String>("adresse") ?: ""
                        val nom = appel.argument<String>("nom") ?: ""
                        g.connecter(adresse, nom, resultat)
                    }
                    "scanner" -> {
                        val duree = (appel.argument<Int>("dureeMs") ?: 8000).toLong()
                        g.scanner(duree, resultat)
                    }
                    "ecrire" -> {
                        val octets = appel.argument<ByteArray>("octets")
                        if (octets == null) {
                            resultat.success(mapOf("ok" to false, "erreur" to "octets absents"))
                        } else {
                            g.ecrire(octets, resultat)
                        }
                    }
                    "memoriser" -> {
                        g.memoriser(
                            appel.argument<String>("adresse") ?: "",
                            appel.argument<String>("nom") ?: "",
                        )
                        resultat.success(mapOf("ok" to true))
                    }
                    "oublier" -> {
                        g.oublier()
                        resultat.success(mapOf("ok" to true))
                    }
                    "deconnecter" -> {
                        g.deconnecter(appel.argument<Boolean>("oublier") == true)
                        resultat.success(mapOf("ok" to true))
                    }
                    else -> resultat.notImplemented()
                }
            }
        // Flux : etats de connexion, appareils vus, octets recus.
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "oret/ble_central_events")
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
                    bleCentral?.brancherFlux(sink)
                }
                override fun onCancel(arguments: Any?) {
                    bleCentral?.brancherFlux(null)
                }
            })

        // Diagnostic terrain BLE (`tool/diag_ble_main.dart`) : les extras
        // d'intent ne sont pas visibles depuis Dart, on les relaie ici.
        // Inactif pour l'application normale, qui n'appelle jamais ce canal.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "oret/diag")
            .setMethodCallHandler { appel, resultat ->
                when (appel.method) {
                    "args" -> {
                        val extras = intent?.extras
                        val sortie = HashMap<String, String>()
                        if (extras != null) {
                            for (cle in extras.keySet()) {
                                if (cle.startsWith("oret_diag_")) {
                                    extras.getString(cle)?.let { sortie[cle] = it }
                                }
                            }
                        }
                        resultat.success(sortie)
                    }
                    else -> resultat.notImplemented()
                }
            }
    }

    // ------------------------------------------------------- permissions

    private fun permissionWifi(): String =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            Manifest.permission.NEARBY_WIFI_DEVICES
        } else {
            Manifest.permission.ACCESS_FINE_LOCATION
        }

    private fun aPermissionWifi(): Boolean =
        ContextCompat.checkSelfPermission(this, permissionWifi()) ==
                PackageManager.PERMISSION_GRANTED

    private fun demanderPermissionWifi() {
        ActivityCompat.requestPermissions(
            this, arrayOf(permissionWifi()), codePermissionWifi
        )
    }

    override fun onRequestPermissionsResult(
        code: Int,
        permissions: Array<out String>,
        results: IntArray
    ) {
        super.onRequestPermissionsResult(code, permissions, results)
        if (code != codePermissionWifi) return
        val accordee = results.isNotEmpty() &&
                results[0] == PackageManager.PERMISSION_GRANTED
        // La demande ne se resout pas dans le meme appel : on rend l'etat
        // pour que Dart retente une fois la permission accordee.
        pendingResult?.success(
            mapOf(
                "ok" to accordee,
                "erreur" to if (accordee) null else "permission Wi-Fi refusee"
            )
        )
        pendingResult = null
    }

    override fun onDestroy() {
        wifiDirect?.liberer()
        wifiDirect = null
        super.onDestroy()
    }
}

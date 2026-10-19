package com.oretracking.ore_tracking

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
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

    private var wifiDirect: WifiDirectManager? = null
    private var pendingResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        wifiDirect = WifiDirectManager(applicationContext)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, canal)
            .setMethodCallHandler { appel, resultat ->
                val gestionnaire = wifiDirect
                if (gestionnaire == null) {
                    resultat.success(mapOf("ok" to false, "erreur" to "gestionnaire absent"))
                    return@setMethodCallHandler
                }
                when (appel.method) {
                    "demarrer" -> {
                        val nom = appel.argument<String>("nom") ?: "ORE-EXC-001"
                        if (!aPermissionWifi()) {
                            // On demande la permission ; la creation du groupe
                            // reprendra a la prochaine tentative de l'appelant.
                            pendingResult = resultat
                            demanderPermissionWifi()
                            return@setMethodCallHandler
                        }
                        gestionnaire.demarrerGroupe(nom) { ok, erreur ->
                            runOnUiThread {
                                resultat.success(mapOf("ok" to ok, "erreur" to erreur))
                            }
                        }
                    }
                    "arreter" -> gestionnaire.arreterGroupe { ok, erreur ->
                        runOnUiThread {
                            resultat.success(mapOf("ok" to ok, "erreur" to erreur))
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
                    "etat" -> resultat.success(mapOf("ok" to true) + gestionnaire.etat())
                    "clients" -> gestionnaire.clients { noms ->
                        runOnUiThread {
                            resultat.success(mapOf("ok" to true, "clients" to noms))
                        }
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

package com.oretracking.ore_tracking

import android.content.Context
import android.net.ConnectivityManager
import android.net.TetheringManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log

/**
 * Active le **partage de connexion systeme** (`TetheringManager`) au lieu de
 * `LocalOnlyHotspot`.
 *
 * **Pourquoi changer de mecanisme.** `LocalOnlyHotspot` applique, depuis
 * Android 13, un filtrage entrant sur l'interface du point d'acces : l'hote
 * accepte ses propres connexions sortantes, mais **refuse le trafic entrant
 * de ses clients**. Mesure sur le terrain :
 *
 *     EXC -> ap0:45210        OUVERT
 *     DT  -> 10.19.117.93    100 % de perte, TCP refuse
 *
 * C'est un comportement voulu par Google (proteger la machine hote), et
 * aucune application non-root ne peut le lever. Le partage de connexion
 * systeme, lui, **ne filtre pas** les clients entre eux.
 *
 * **Limite honnete.** `TetheringManager` est accessible aux applications
 * ordinaires depuis Android 11, mais certains fabricants le restreignent.
 * Chaque methode rend donc `ok=false` avec un motif lisible plutot que de
 * lever : l'application retombe alors sur `LocalOnlyHotspot`.
 */
class PartageConnexion(private val context: Context) {

    companion object {
        private const val TAG = "OreTethering"

        /** SSID annonce par le partage : prefixe stable et reconnaissable. */
        const val SSID = "ORE-EXC"

        /** Mot de passe fixe : contrairement a LocalOnlyHotspot, il est choisi. */
        const val MOT_DE_PASSE = "oretracking"
    }

    private val handler = Handler(Looper.getMainLooper())

    /** Vrai si l'appareil expose ce service (Android 11+). */
    fun estDisponible(): Boolean = Build.VERSION.SDK_INT >= Build.VERSION_CODES.R

    /**
     * Active le partage de connexion.
     *
     * @param onResultat `(ok, erreur)` sur le thread principal.
     */
    fun demarrer(onResultat: (Boolean, String?) -> Unit) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            onResultat(false, "Android 11 requis pour TetheringManager")
            return
        }
        val tm: TetheringManager? = try {
            context.getSystemService(TetheringManager::class.java)
        } catch (e: Exception) {
            Log.w(TAG, "Service indisponible : ${e.message}")
            null
        }
        if (tm == null) {
            onResultat(false, "TetheringManager absent sur cet appareil")
            return
        }
        try {
            // Android 14+ : demarrage par chaine de type ("wifi").
            // Android 11-13 : meme API, disponible depuis TIRAMISU en pratique.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                val exec = java.util.concurrent.Executor { r -> handler.post(r) }
                tm.startTethering(
                    TetheringManager.TetheringRequest.Builder(
                        TetheringManager.TETHERING_WIFI,
                    ).build(),
                    exec,
                    object : TetheringManager.StartTetheringCallback {
                        override fun onTetheringStarted() {
                            Log.i(TAG, "Partage de connexion demarre")
                            onResultat(true, null)
                        }

                        override fun onTetheringFailed(error: Int) {
                            Log.w(TAG, "Echec du partage (code $error)")
                            onResultat(false, "echec du partage (code $error)")
                        }
                    },
                )
            } else {
                onResultat(false, "version Android non geree (${Build.VERSION.SDK_INT})")
            }
        } catch (e: SecurityException) {
            onResultat(
                false,
                "permission refusee : le fabricant restreint le partage aux apps systeme",
            )
        } catch (e: Exception) {
            onResultat(false, "partage impossible : ${e.message}")
        }
    }

    /** Etat tel que la couche applicative le journalise. */
    fun etat(): Map<String, Any?> = mapOf(
        "disponible" to estDisponible(),
        "ssid" to SSID,
        "motDePasse" to MOT_DE_PASSE,
    )

    // ------------------------------------------------------------------
    // Partage actif par l'OPERATEUR (refonte 21/10).
    //
    // `TETHER_PRIVILEGED` n'est pas accordable aux apps ordinaires (observe
    // : TETHER_ERROR_NO_CHANGE_TETHERING_PERMISSION sur Android 15). La voie
    // reelle : l'operateur active le partage dans les REGLAGES Android (une
    // fois, memorise), et l'application DETECTE ce partage et l'UTILISE.
    // Contrairement au LocalOnlyHotspot, le partage systeme ne filtre pas
    // les clients : le TCP de l'excavatrice devient joignable.
    // ------------------------------------------------------------------

    /**
     * Le partage systeme (operationnel) est-il deja actif — active par
     * l'operateur dans les Reglages ?
     *
     * Detection par l'interface reseau : Android nomme l'interface du partage
     * `ap0`. Une interface presente avec une adresse IPv4 = un partage qui
     * emet vraiment. On ne regarde PAS le WorkSource : notre propre demande
     * `startTethering` echouee ne cree jamais d'interface, donc une interface
     * presente est forcement le partage (notre app ou l'operateur — et si
     * c'est la notre, c'est que le fabricant l'a autorisee, tant mieux).
     */
    fun partageActif(): Boolean = adressePartage() != null

    /**
     * Adresse IPv4 de l'interface de partage (`ap0`), ou null.
     *
     * C'est l'adresse que les clients joignent en TCP (port 45210).
     */
    fun adressePartage(): String? {
        return try {
            val interfaces = java.net.NetworkInterface.getNetworkInterfaces()
            for (i in interfaces) {
                val nom = i.name ?: continue
                if (nom != "ap0" && !nom.startsWith("ap")) continue
                for (a in i.inetAddresses) {
                    val ip = a.hostAddress ?: continue
                    if (a is java.net.Inet4Address && !a.isLoopbackAddress) return ip
                }
            }
            null
        } catch (_: Exception) {
            null
        }
    }

    /**
     * Lit la configuration REELLE du point d'acces systeme.
     *
     * Aucune voie SDK publique ne reste lisible sur Android 15 :
     * `getWifiApConfiguration` et `getSoftApConfiguration` ont ete retires du
     * SDK pour les apps tierces (verification au build). L'application fait
     * donc confiance aux Parametres de l'app : l'operateur y saisit SSID et
     * mot de passe **une fois** (`reseau_ssid`/`reseau_mot_de_passe`), et le
     * provisionnement BLE les annonce aux DT. Rend des champs vides : le
     * caller combine avec les Parametres.
     */
    fun configPartage(): Map<String, Any?> {
        return mapOf("ssid" to null, "motDePasse" to null)
    }

    /**
     * Ouvre les REGLAGES du point d'acces pour que l'operateur active le
     * partage lui-meme.
     *
     * On vise l'ecran systeme du tethering (TetherSettings) ; en repli, le
     * panneau Internet. Aucun privilege requis : c'est une intention vers
     * l'UI du systeme, comme n'importe quelle app.
     */
    fun ouvrirReglagesPartage() {
        val cible = try {
            // TetherSettings est le composant des Reglages (AOSP, stable).
            android.content.Intent().setClassName(
                "com.android.settings",
                "com.android.settings.TetherSettings",
            )
        } catch (_: Exception) {
            null
        }
        try {
            context.applicationContext.startActivity(
                (cible ?: android.content.Intent(
                    android.provider.Settings.ACTION_WIRELESS_SETTINGS,
                )).addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK),
            )
            Log.i(TAG, "Reglages du partage ouverts")
        } catch (e: Exception) {
            Log.w(TAG, "Ouverture des reglages impossible : ${e.message}")
        }
    }
}

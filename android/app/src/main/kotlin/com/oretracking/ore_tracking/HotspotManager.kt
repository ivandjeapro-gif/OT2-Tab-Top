package com.oretracking.ore_tracking

import android.content.Context
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Point d'acces local cote excavatrice, via `LocalOnlyHotspot`.
 *
 * **Pourquoi ce n'est pas Wi-Fi Direct.** `WifiP2pManager` impose son propre
 * groupe et refuse la creation sur plusieurs tablettes Android 15 (code 2,
 * `ERROR`) ; il exige aussi un nom `DIRECT-xy`. `LocalOnlyHotspot` est une API
 * du framework, stable depuis Android 8 : le systeme cree le reseau, en rend
 * le SSID et le mot de passe, et n'impose aucune contrainte de nom.
 *
 * **Ce que ce n'est pas.** Ce n'est pas `startLocalOnlyHotspot` « avec
 * Internet » : comme son nom l'indique, le point d'acces est **local
 * uniquement**. C'est exactement ce qu'il faut ici — l'excavatrice n'a pas de
 * 4G, c'est le DT qui pousse vers le serveur. Le reseau sert a faire circuler
 * le TCP applicatif (port 45210) entre les trois tablettes.
 *
 * **Android 13+** demande `NEARBY_WIFI_DEVICES` ; en dessous, la localisation
 * fine est obligatoire pour demarrer un hotspot. Les deux sont declarees au
 * manifeste ; la couche Dart demande les permissions runtime avant d'appeler.
 *
 * Aucune exception ne remonte vers Dart : chaque methode rend un `ok`/`erreur`.
 */
class HotspotManager(private val context: Context) {

    companion object {
        private const val TAG = "OreHotspot"

        /** Prefixe du SSID : les clients le reconnaissent a ce prefixe. */
        const val PREFIXE_SSID = "ORE-EXC"

        /**
         * Mot de passe par defaut du point d'acces.
         *
         * WPA2 impose 8 caracteres minimum : c'est le cas. Il est fixe pour
         * que le reseau garde **la meme identite a chaque demarrage** — sans
         * cela, Android en genere un nouveau a chaque appel et les tablettes
         * deja enrolees doivent ressaisir les identifiants, ce qui n'est pas
         * acceptable sur le terrain.
         */
        const val MOT_DE_PASSE_DEFAUT = "oretracking"
    }

    private val wifi: WifiManager? =
        context.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager

    /** Reservation en cours : elle porte le point d'acces tant qu'elle vit. */
    private var reservation: WifiManager.LocalOnlyHotspotReservation? = null

    /** SSID et mot de passe reellement attribues par Android. */
    private var ssidActuel: String? = null
    private var motDePasseActuel: String? = null

    private val demarrageEnCours = AtomicBoolean(false)
    private val handler = Handler(Looper.getMainLooper())

    /** Vrai si l'appareil sait ouvrir un point d'acces local. */
    fun estDisponible(): Boolean =
        wifi != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O

    /**
     * Demarre le point d'acces local.
     *
     * @param nomGroupe prefixe souhaite ; Android peut le completer pour
     *   garantir l'unicite (`ORE-EXC-001-ab12`). Les clients se connectent
     *   donc sur le SSID **rendu**, jamais sur le nom demande.
     * @param onResultat (ok, erreur, ssid, motDePasse), sur le thread principal.
     */
    fun demarrer(
        nomGroupe: String,
        @Suppress("UNUSED_PARAMETER") motDePasse: String = MOT_DE_PASSE_DEFAUT,
        onResultat: (Boolean, String?, String?, String?, String?) -> Unit,
    ) {
        val w = wifi
        if (w == null) {
            onResultat(false, "Wi-Fi indisponible sur cet appareil", null, null, null)
            return
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            onResultat(false, "Android 8 requis pour un point d'acces local", null, null, null)
            return
        }
        // Second appel pendant l'ouverture : Android refuse deux reservations
        // et rend dans ce cas un code generique. On repond l'etat courant.
        if (!demarrageEnCours.compareAndSet(false, true)) {
            onResultat(false, "demarrage deja en cours", null, null, null)
            return
        }
        // Une reservation deja ouverte est reutilisee : c'est le cas courant
        // quand l'utilisateur navigue entre les ecrans.
        val ouverte = reservation
        if (ouverte != null) {
            demarrageEnCours.set(false)
            onResultat(
                true, null, ssidActuel, motDePasseActuel, adresseHotspot(),
            )
            return
        }

        // Voie 1 — configuration fixe : IMPOSSIBLE pour une application
        // ordinaire. `SoftApConfiguration.Builder.setSsid/setPassphrase` sont
        // @SystemApi (invisibles du SDK public : verifie dans android.jar,
        // seules `setChannels` et `getBytes` y figurent), et
        // `startLocalOnlyHotspotWithConfiguration` exige NETWORK_SETTINGS.
        // On garde donc la voie publique et on compense cote application :
        // l'excavatrice publie son SSID/mot de passe, le client le rejoint en
        // une fois (voir `provisionnement`).
        try {
            w.startLocalOnlyHotspot(callbackReservation(onResultat), handler)
        } catch (e: SecurityException) {
            demarrageEnCours.set(false)
            // Android 13+ : NEARBY_WIFI_DEVICES, avant : localisation fine.
            onResultat(
                false,
                "permission manquante : accordez l'acces a proximite et activez la localisation",
                null, null, null,
            )
        } catch (e: Exception) {
            demarrageEnCours.set(false)
            // Certains OEM levent IllegalStateException quand la radio est
            // occupee : la couche au-dessus retentera.
            onResultat(
                false, "impossible de demarrer le point d'acces : ${e.message}",
                null, null, null,
            )
        }
    }

    /** Callback commun aux deux voies (fixe et aleatoire). */
    private fun callbackReservation(
        onResultat: (Boolean, String?, String?, String?, String?) -> Unit,
    ): WifiManager.LocalOnlyHotspotCallback {
        return object : WifiManager.LocalOnlyHotspotCallback() {
                override fun onStarted(res: WifiManager.LocalOnlyHotspotReservation) {
                    reservation = res
                    // Le SSID reel est celui du SoftApConfiguration : Android
                    // l'a suffixe pour eviter les collisions entre appareils.
                    ssidActuel = try {
                        res.softApConfiguration.ssid
                    } catch (_: Exception) {
                        null
                    }
                    motDePasseActuel = try {
                        res.softApConfiguration.passphrase
                    } catch (_: Exception) {
                        null
                    }
                    demarrageEnCours.set(false)
                    Log.i(TAG, "Hotspot demarre : SSID=$ssidActuel")
                    poster {
                        onResultat(
                            true, null, ssidActuel, motDePasseActuel,
                            adresseHotspot(),
                        )
                    }
                }

                override fun onStopped() {
                    reservation = null
                    demarrageEnCours.set(false)
                    Log.i(TAG, "Hotspot arrete par le systeme")
                }

                override fun onFailed(reason: Int) {
                    reservation = null
                    demarrageEnCours.set(false)
                    val motif = when (reason) {
                        ERROR_NO_CHANNEL -> "aucun canal Wi-Fi disponible"
                        ERROR_INCOMPATIBLE_MODE -> "mode Wi-Fi incompatible (coupez le Wi-Fi Direct)"
                        ERROR_TETHERING_DISALLOWED -> "partage de connexion interdit par l'appareil"
                        ERROR_GENERIC -> "refus du systeme"
                        else -> "echec du point d'acces (code $reason)"
                    }
                    Log.w(TAG, "Hotspot refuse : $motif")
                    poster {
                        onResultat(false, motif, null, null, null)
                    }
                }
            }
    }

    /** Ferme le point d'acces : l'excavatrice cesse d'etre accessible. */
    fun arreter(onResultat: (Boolean, String?) -> Unit) {
        val r = reservation
        reservation = null
        ssidActuel = null
        motDePasseActuel = null
        if (r == null) {
            onResultat(false, "aucun point d'acces ouvert")
            return
        }
        try {
            r.close()
            Log.i(TAG, "Hotspot ferme")
            onResultat(true, null)
        } catch (e: Exception) {
            onResultat(false, "fermeture du point d'acces refusee : ${e.message}")
        }
    }

    /** Etat tel que la couche applicative l'affiche et le journalise. */
    fun etat(): Map<String, Any?> = mapOf(
        "disponible" to estDisponible(),
        "actif" to (reservation != null),
        "ssid" to ssidActuel,
        "motDePasse" to motDePasseActuel,
        // IP de l'interface du point d'acces : c'est elle que les clients
        // doivent joindre pour le TCP applicatif.
        "adresseGroupOwner" to adresseHotspot(),
    )

    /**
     * Adresse IPv4 de l'interface du point d'acces.
     *
     * Android la place generalement sur `192.168.43.1` (historique) ou
     * `192.168.x.1` selon la version ; on lit l'interface pour ne pas la
     * supposer. Rend null tant que le hotspot n'a pas attribue d'interface.
     */
    private fun adresseHotspot(): String? {
        return try {
            val interfaces = java.net.NetworkInterface.getNetworkInterfaces()
            for (i in interfaces) {
                val nom = i.name ?: continue
                if (!nom.startsWith("ap") && !nom.startsWith("wlan")) continue
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

    private fun poster(bloc: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) bloc() else handler.post(bloc)
    }
}

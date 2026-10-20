package com.oretracking.ore_tracking

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiConfiguration
import android.net.wifi.WifiManager
import android.net.wifi.WifiNetworkSpecifier
import android.net.wifi.WifiNetworkSuggestion
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Rapproche une tablette cliente (DT, spotter) du point d'acces de
 * l'excavatrice.
 *
 * **Pourquoi pas un simple scan.** Le point d'acces vient de
 * `LocalOnlyHotspot` : son SSID est impose par Android (`AndroidShare_1234`,
 * `DIRECT-...`) et change a chaque demarrage. On ne peut donc pas « chercher
 * le reseau ORE-EXC ». Ce sont les identifiants **re reellement attribues**
 * qu'il faut utiliser — l'excavatrice les affiche, ce sont eux qu'on saisit.
 *
 * **Deux voies, selon la version :**
 * - Android 10+ : `WifiNetworkSpecifier` — connexion ciblee, sans toucher aux
 *   autres reseaux enregistres.
 * - Android 8/9 : `WifiConfiguration` classique.
 *
 * Une suggestion de reseau est aussi deposee : Android la memorise et
 * reconnexion automatique les fois suivantes, sans nouvelle saisie.
 */
class WifiClientManager(private val context: Context) {

    companion object {
        private const val TAG = "OreWifiClient"
    }

    private val wifi: WifiManager? =
        context.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager

    private val connectivite: ConnectivityManager? =
        context.applicationContext.getSystemService(Context.CONNECTIVITY_SERVICE)
                as? ConnectivityManager

    private val handler = Handler(Looper.getMainLooper())
    private val enCours = AtomicBoolean(false)

    private var callbackReseau: ConnectivityManager.NetworkCallback? = null
    private var reseauActif: Network? = null

    /**
     * Rejoint [ssid] avec [motDePasse].
     *
     * @param onResultat (ok, erreur) sur le thread principal.
     */
    fun connecter(
        ssid: String,
        motDePasse: String,
        onResultat: (Boolean, String?) -> Unit,
    ) {
        val w = wifi
        val cm = connectivite
        if (w == null || cm == null) {
            onResultat(false, "Wi-Fi indisponible sur cet appareil")
            return
        }
        if (ssid.isBlank()) {
            onResultat(false, "SSID vide : aucun point d'acces annonce")
            return
        }
        if (!enCours.compareAndSet(false, true)) {
            onResultat(false, "connexion deja en cours")
            return
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            joindreAvecSpecifier(cm, ssid, motDePasse, onResultat)
        } else {
            joindreAvecConfiguration(w, ssid, motDePasse, onResultat)
        }
    }

    /**
     * Android 10+ : `WifiNetworkSpecifier` cible un SSID precis.
     *
     * C'est la seule voie qui force l'association **meme si un autre Wi-Fi
     * est deja connecte** : le systeme ouvre une interface dediee a cette
     * demande. Sans cela, un reseau d'entreprise en `/8` (ex. `10.0.0.0/8`)
     * fait croire a Android que le point d'acces est deja joignable, et il ne
     * change jamais de reseau.
     */
    private fun joindreAvecSpecifier(
        cm: ConnectivityManager,
        ssid: String,
        motDePasse: String,
        onResultat: (Boolean, String?) -> Unit,
    ) {
        val specifier = WifiNetworkSpecifier.Builder()
            .setSsid(ssid)
            .setWpa2Passphrase(motDePasse)
            .build()

        val requete = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .setNetworkSpecifier(specifier)
            .build()

        // Un seul callback a la fois : on annule le precedent sans le
        // considerer comme un echec (il peut etre simplement remplace).
        callbackReseau?.let {
            try {
                cm.unregisterNetworkCallback(it)
            } catch (_: Exception) {
                // Deja desenregistre.
            }
        }
        callbackReseau = null

        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                reseauActif = network
                enCours.set(false)
                Log.i(TAG, "Reseau $ssid rejoint")
                poster { onResultat(true, null) }
            }

            override fun onUnavailable() {
                reseauActif = null
                enCours.set(false)
                Log.w(TAG, "Reseau $ssid indisponible ou mot de passe refuse")
                poster {
                    onResultat(
                        false,
                        "point d'acces introuvable ou mot de passe refuse",
                    )
                }
            }

            override fun onLost(network: Network) {
                if (reseauActif == network) reseauActif = null
                Log.i(TAG, "Reseau $ssid perdu")
            }
        }
        callbackReseau = callback

        try {
            cm.requestNetwork(requete, callback, DELAI_MS)
        } catch (e: SecurityException) {
            enCours.set(false)
            onResultat(
                false,
                "permission manquante : accordez l'acces a proximite et activez la localisation",
            )
        } catch (e: Exception) {
            enCours.set(false)
            onResultat(false, "connexion impossible : ${e.message}")
        }
    }

    /** Android 8/9 : configuration classique, memorisee par le systeme. */
    @Suppress("DEPRECATION")
    private fun joindreAvecConfiguration(
        w: WifiManager,
        ssid: String,
        motDePasse: String,
        onResultat: (Boolean, String?) -> Unit,
    ) {
        try {
            val config = WifiConfiguration().apply {
                SSID = "\"$ssid\""
                preSharedKey = "\"$motDePasse\""
                status = WifiConfiguration.Status.ENABLED
            }
            val id = w.addNetwork(config)
            if (id < 0) {
                enCours.set(false)
                onResultat(false, "reseau refuse par le systeme")
                return
            }
            w.disconnect()
            val ok = w.enableNetwork(id, true) && w.reconnect()
            enCours.set(false)
            onResultat(ok, if (ok) null else "association refusee")
        } catch (e: Exception) {
            enCours.set(false)
            onResultat(false, "connexion impossible : ${e.message}")
        }
    }

    /**
     * Depose une suggestion de reseau (Android 10+) : le systeme memorise le
     * point d'acces et s'y reconnecte de lui-meme aux fois suivantes.
     */
    fun memoriser(ssid: String, motDePasse: String): Boolean {
        val w = wifi ?: return false
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return false
        if (ssid.isBlank()) return false
        return try {
            val suggestion = WifiNetworkSuggestion.Builder()
                .setSsid(ssid)
                .setWpa2Passphrase(motDePasse)
                .setIsAppInteractionRequired(false)
                .build()
            w.addNetworkSuggestions(listOf(suggestion)) ==
                WifiManager.STATUS_NETWORK_SUGGESTIONS_SUCCESS
        } catch (e: Exception) {
            Log.w(TAG, "Memoire du reseau refusee : ${e.message}")
            false
        }
    }

    /** Adresse IPv4 de l'interface Wi-Fi (celle qui joint le serveur TCP). */
    fun adresseLocale(): String? {
        return try {
            for (i in java.net.NetworkInterface.getNetworkInterfaces()) {
                if (!i.name.startsWith("wlan")) continue
                if (!i.isUp) continue
                for (a in i.inetAddresses) {
                    if (a is java.net.Inet4Address && !a.isLoopbackAddress) {
                        return a.hostAddress
                    }
                }
            }
            null
        } catch (_: Exception) {
            null
        }
    }

    fun etat(): Map<String, Any?> = mapOf(
        "connecte" to (reseauActif != null),
        "adresseLocale" to adresseLocale(),
    )

    private fun poster(bloc: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) bloc() else handler.post(bloc)
    }
}

/** Delai laisse au systeme pour s'associer avant d'abandonner. */
private const val DELAI_MS = 30_000

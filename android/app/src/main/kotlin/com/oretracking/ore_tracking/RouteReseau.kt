package com.oretracking.ore_tracking

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Build
import android.util.Log

/**
 * Garde le trafic **serveur** sur le reseau cellulaire quand la tablette est
 * par ailleurs connectee au point d'acces local de l'excavatrice.
 *
 * **Le probleme.** Le point d'acces venu de `LocalOnlyHotspot` n'a pas
 * d'Internet : des que le DT ou le spotter s'y associe, Android fait passer
 * TOUT le trafic par ce Wi-Fi. Les appels vers Google Apps Script echouent
 * alors que la 4G est presente et fonctionnelle — le badge 4G passe au rouge
 * et les referentiels ne se chargent plus.
 *
 * **La solution.** On demande au systeme une liaison dediee a la **cellulaire**
 * (`requestNetwork`), on l'attache au processus (`bindProcessToNetwork`), puis
 * on declare le point d'acces comme « non facturable » : le TCP local continue
 * de passer par le Wi-Fi sans etre rompu.
 *
 * Aucune exception ne remonte vers Dart : chaque methode rend un booleen.
 */
class RouteReseau(private val context: Context) {

    companion object {
        private const val TAG = "OreRoute"
    }

    private val cm: ConnectivityManager? =
        context.applicationContext.getSystemService(Context.CONNECTIVITY_SERVICE)
                as? ConnectivityManager

    private var callback: ConnectivityManager.NetworkCallback? = null
    private var reseauCellulaire: Network? = null

    /**
     * Force le trafic du processus sur la 4G.
     *
     * Sans effet (et sans erreur) si l'appareil n'a pas de reseau cellulaire :
     * la tablette reste alors sur sa route par defaut.
     */
    fun forcerCellulaire(): Boolean {
        val c = cm ?: return false
        if (reseauCellulaire != null) return true

        val requete = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_CELLULAR)
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .build()

        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                reseauCellulaire = network
                // **On ne lie PAS le processus.** `bindProcessToNetwork` pose
                // une table de routage (1015) qui capture TOUT, y compris les
                // paquets vers 10.19.117.93 — le point d'acces local. Resultat
                // mesure : le DT envoyait sa telemetrie vers l'excavatrice
                // dans la 4G, ou cette adresse n'existe pas, et le ping perdait
                // 100 % des paquets.
                //
                // La liaison se fait desormais **socket par socket**, cote
                // HTTP (`recevoir()`), uniquement pour le trafic serveur.
                Log.i(TAG, "Route cellulaire prete : $network (liaison par socket)")
            }

            override fun onLost(network: Network) {
                if (reseauCellulaire == network) {
                    reseauCellulaire = null
                    Log.w(TAG, "Reseau cellulaire perdu : retour a la route par defaut")
                }
            }
        }
        callback = cb
        return try {
            c.requestNetwork(requete, cb)
            true
        } catch (e: SecurityException) {
            Log.w(TAG, "Permission reseau manquante", e)
            false
        } catch (e: Exception) {
            Log.w(TAG, "Route cellulaire indisponible : ${e.message}", e)
            false
        }
    }

    /** Rend la main a la route par defaut du systeme. */
    fun liberer() {
        val c = cm ?: return
        callback?.let {
            try {
                c.unregisterNetworkCallback(it)
            } catch (_: Exception) {
                // Deja desenregistre.
            }
        }
        callback = null
        reseauCellulaire = null
        Log.i(TAG, "Route par defaut rendue")
    }

    /**
     * Lie **une seule socket** a la 4G.
     *
     * C'est le bon grain : le trafic serveur sort par la 4G, le trafic local
     * (TCP vers l'excavatrice, sur le point d'acces) garde sa route Wi-Fi.
     * Rend false si aucun reseau cellulaire n'est disponible — l'appelant
     * laisse alors la socket sur la route par defaut.
     */
    fun lierSocketCellulaire(socket: java.net.Socket): Boolean {
        val n = reseauCellulaire ?: return false
        return try {
            n.bindSocket(socket)
            true
        } catch (e: Exception) {
            Log.w(TAG, "Liaison de socket impossible : ${e.message}")
            false
        }
    }

    /** Vrai si une route cellulaire est disponible pour lier des sockets. */
    fun cellulairePrete(): Boolean = reseauCellulaire != null

    fun etat(): Map<String, Any?> = mapOf(
        "cellulaireForce" to (reseauCellulaire != null),
        // Etat REEL de la radio cellulaire, lu directement chez Android.
        //
        // `connectivity_plus` resume le reseau en categories et perd
        // l'information quand un Wi-Fi secondaire est present : sur un
        // portail captif (`CAPTIVE_PORTAL`), il ne rend aucun reseau valide
        // alors que la 4G est connectee et `VALIDATED`. Le badge restait
        // donc faux sur le spotter et juste sur le DT (qui n'a pas de Wi-Fi).
        "cellulaire" to cellulaireDisponible(),
    )

    /** La radio cellulaire porte-t-elle un reseau valide ? */
    fun cellulaireDisponible(): Boolean {
        val c = cm ?: return false
        return testeCellulaire(c, c.activeNetwork)
    }

    /**
     * Verifie qu'un reseau donne est vraiment cellulaire ET reellement sortant.
     *
     * **Pourquoi pas seulement INTERNET.** Sur ce terrain, l'interface
     * cellulaire survit a la coupure de la donnee mobile : elle garde son
     * agent reseau et sa capacite INTERNET alors qu'elle n'a plus d'adresse
     * IP (verifie : `ccmni1` vide, `ping 8.8.8.8` a 100 % de perte, mais
     * `mobile_data` reste a 1). Un test sur INTERNET seul rendait donc
     * « disponible » une 4G morte.
     *
     * Les deux criteres qui ne peuvent pas mentir :
     * - `VALIDATED` : le systeme a confirme un acces Internet reel ;
     * - une adresse IP attribuee : sans elle, aucune route n'existe.
     */
    private fun testeCellulaire(c: ConnectivityManager, n: Network?): Boolean {
        val reseau = n ?: return false
        return try {
            val caps = c.getNetworkCapabilities(reseau) ?: return false
            val cellulaire = caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR)
            val internet = caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            val valide = caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
            val adresse = c.getLinkProperties(reseau)?.linkAddresses?.any {
                it.address is java.net.Inet4Address
            } ?: false
            // Trace de diagnostic : dit EXACTEMENT quel critere fait defaut.
            // Sans cela, un badge rouge ne permet pas de distinguer « pas de
            // 4G » de « 4G presente mais non validee » — et c'est ce qui nous
            // a fait corriger a l'aveugle plusieurs fois.
            Log.i(
                TAG,
                "CELL net=$reseau transport=$cellulaire internet=$internet " +
                    "valide=$valide adresse=$adresse",
            )
            cellulaire && internet && valide && adresse
        } catch (_: Exception) {
            false
        }
    }

    /**
     * La 4G existe-t-elle, meme si un Wi-Fi la masque ?
     *
     * `activeNetwork` ne rend qu'un reseau : celui par defaut. Quand un
     * portail captif prend la main, la 4G disparait de la reponse alors
     * qu'elle est connectee. On parcourt donc TOUS les reseaux.
     */
    fun cellulaireSousJacente(): Boolean {
        val c = cm ?: return false
        return try {
            c.allNetworks.any { n -> testeCellulaire(c, n) }
        } catch (_: Exception) {
            false
        }
    }

    /**
     * Sonde **active** : un paquet passe-t-il vraiment par la 4G ?
     *
     * **Pourquoi ne plus croire les drapeaux.** Sur ce terrain, apres
     * coupure de la donnee mobile, Android continue d'exposer un reseau
     * `MOBILE[LTE] CONNECTED VALIDATED` avec la capacite INTERNET — alors que
     * `ccmni1` n'a aucune adresse et que `ping 8.8.8.8` perd 100 % des
     * paquets. Lire l'etat du systeme donne donc du vert sur une 4G morte.
     *
     * On ouvre donc une socket vers un hote public **en la liant au reseau
     * cellulaire** : si la connexion aboutit, la route existe reellement.
     * C'est la seule mesure qui corresponde au terrain.
     *
     * @param hote nom d'hote joint par TCP (port 53 : jamais filtre).
     * @param delaiMs delai maximal ; au-dela, on considere la route morte.
     */
    fun sondeCellulaire(
        hote: String = "8.8.8.8",
        port: Int = 53,
        delaiMs: Int = 4000,
    ): Boolean {
        val c = cm ?: return false
        val specs = c.allNetworks.filter { n ->
            val caps = c.getNetworkCapabilities(n) ?: return@filter false
            caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR)
        }
        if (specs.isEmpty()) {
            Log.i(TAG, "SONDE 4G : aucun reseau cellulaire declare")
            return false
        }
        for (n in specs) {
            try {
                // `bindSocket` force CE paquet a sortir par CE reseau : sans
                // lui, Android pourrait router la sonde par le Wi-Fi et
                // repondre « la 4G marche » alors qu'elle est coupee.
                val socket = java.net.Socket()
                n.bindSocket(socket)
                socket.connect(java.net.InetSocketAddress(hote, port), delaiMs)
                socket.close()
                Log.i(TAG, "SONDE 4G : OK sur $n")
                return true
            } catch (e: Exception) {
                Log.i(TAG, "SONDE 4G : echec sur $n (${e.message})")
            }
        }
        return false
    }
}

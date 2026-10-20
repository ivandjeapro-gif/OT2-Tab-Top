package com.oretracking.ore_tracking

import android.Manifest
import android.annotation.SuppressLint
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.net.MacAddress
import android.net.wifi.p2p.WifiP2pConfig
import android.net.wifi.p2p.WifiP2pDevice
import android.net.wifi.p2p.WifiP2pInfo
import android.net.wifi.p2p.WifiP2pManager
import android.os.Build
import android.os.Looper
import android.util.Log
import androidx.core.content.ContextCompat

/**
 * Point d'acces Wi-Fi Direct cote excavatrice (role « Group Owner »).
 *
 * Pourquoi Wi-Fi Direct et pas un hotspot classique : sur Android 11+ (et
 * surtout 13+), `WifiManager.startLocalOnlyHotspot()` est reserve aux
 * applications systeme — une app ordinaire ne peut plus creer de partage de
 * connexion. `WifiP2pManager` reste, lui, une API publique : l'excavatrice
 * devient Group Owner (elle joue le point d'acces), les DT deviennent des
 * clients. C'est la seule voie automatique, sans manipulation manuelle de
 * l'utilisateur.
 *
 * Limite assumee : Wi-Fi Direct impose son propre groupe reseau (souvent
 * 192.168.49.x) — l'application n'ouvre donc plus son serveur TCP « dans le
 * vide », elle l'ouvre sur cette interface, et les DT s'y connectent avec
 * l'adresse du Group Owner que `requestGroupInfo` expose.
 *
 * Aucune exception ne remonte vers Dart : chaque methode rend un resultat
 * structure (`ok`/`erreur`) que la couche applicative journalise.
 */
class WifiDirectManager(private val context: Context) {

    companion object {
        private const val TAG = "OreWifiDirect"

        /** Nom du groupe annonce : les DT le reconnaissent a ce prefixe. */
        const val PREFIXE_GROUPE = "ORE-EXC"

        /** Mot de passe du groupe (WPA2, 8 caracteres minimum). */
        const val MOT_DE_PASSE = "oretracking"
    }

    private val manager: WifiP2pManager? =
        context.getSystemService(Context.WIFI_P2P_SERVICE) as? WifiP2pManager

    private var channel: WifiP2pManager.Channel? = null
    private var recepteur: BroadcastReceiver? = null

    /** Etat courant du groupe, tenu a jour par le recepteur. */
    private var infoGroupe: WifiP2pInfo? = null
    private var estGroupeProprietaire: Boolean = false
    private var adresseGroupe: String? = null

    /** Pairs decouverts lors du dernier scan (mode client). */
    private var pairs: List<WifiP2pDevice> = emptyList()

    /** Vrai si la pile Wi-Fi Direct est utilisable sur cet appareil. */
    fun estDisponible(): Boolean = manager != null

    /**
     * Cree le groupe et force l'excavatrice en Group Owner.
     *
     * @param nomGroupe nom annonce (prefixe ORE-EXC + identifiant).
     * @param onResultat rendu sur le thread principal : `true` = groupe cree.
     */
    fun demarrerGroupe(nomGroupe: String, onResultat: (Boolean, String?) -> Unit) {
        val m = manager
        if (m == null) {
            onResultat(false, "Wi-Fi Direct indisponible sur cet appareil")
            return
        }
        if (!aPermissions()) {
            onResultat(false, "Permission NEARBY_WIFI_DEVICES manquante")
            return
        }

        channel = m.initialize(context, Looper.getMainLooper()) {
            // Perte du canal : la pile a lache, l'appelant devra retenter.
            Log.w(TAG, "Canal Wi-Fi Direct perdu")
        }
        val c = channel ?: run {
            onResultat(false, "Canal Wi-Fi Direct non initialise")
            return
        }

        enregistrerRecepteur(c)

        // `createGroup` laisse Android choisir ; on force le role Group Owner
        // juste apres, ce qui est le point clé : sans cela l'excavatrice
        // pourrait etre cliente de son propre groupe.
        m.createGroup(c, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                forcerGroupOwner(c, nomGroupe, onResultat)
            }

            override fun onFailure(raison: Int) {
                // Le groupe existe deja (usage courant : on relance l'app) :
                // on tente alors directement la promotion Group Owner.
                Log.w(TAG, "createGroup a echoue ($raison) — tentative de reprise")
                forcerGroupOwner(c, nomGroupe, onResultat)
            }
        })
    }

    private fun forcerGroupOwner(
        c: WifiP2pManager.Channel,
        nomGroupe: String,
        onResultat: (Boolean, String?) -> Unit
    ) {
        val m = manager ?: return
        // Android 10+ (et Android 15 de facon stricte) impose un nom de
        // groupe commencant par `DIRECT-` suivi de deux caracteres
        // alphanumeriques : `setNetworkName` LEVE IllegalArgumentException
        // sinon, et l'exception remonte sur le thread principal (crash de
        // l'application). On ne peut donc pas y passer `ORE-EXC-001`.
        //
        // Le nom applicatif reste connu des tablettes : il passe par le
        // SSID du groupe, que l'on retrouve cote client via `wifiP2pInfo`.
        val nomConforme = nomGroupeDirect(nomGroupe)
        val config = try {
            WifiP2pConfig.Builder()
                .setNetworkName(nomConforme)
                .setPassphrase(MOT_DE_PASSE)
                .build()
        } catch (e: IllegalArgumentException) {
            // Ceinture et bretelles : une configuration refusee par le
            // framework ne doit jamais faire tomber l'application, qui doit
            // rester capable de travailler en TCP sur un reseau existant.
            Log.w(TAG, "Configuration du groupe refusee ($nomGroupe)", e)
            onResultat(false, "nom de groupe refuse par Android : ${e.message}")
            return
        }

        m.createGroup(c, config, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                estGroupeProprietaire = true
                Log.i(TAG, "Groupe $nomGroupe cree en Group Owner")
                m.requestGroupInfo(c) { groupe ->
                    adresseGroupe = groupe?.owner?.deviceAddress
                    onResultat(true, null)
                }
            }

            override fun onFailure(raison: Int) {
                onResultat(false, "creation du groupe refusee (code $raison)")
            }
        })
    }

    /**
     * Rend un nom de groupe acceptable par le framework Wi-Fi Direct.
     *
     * Format impose : `DIRECT-` + exactement deux caracteres alphanumeriques
     * (ex. `DIRECT-XY`). Un nom deja conforme est retourne tel quel ; sinon on
     * derive deux caracteres stables du nom applicatif, afin que toutes les
     * tablettes retrouvent le meme groupe d'une session a l'autre.
     */
    private fun nomGroupeDirect(nom: String): String {
        val prefixe = "DIRECT-"
        val brut = (nom.ifBlank { "ORE" }).uppercase().filter { it.isLetterOrDigit() }
        if (brut.startsWith("DIRECT") && brut.length == prefixe.length + 2) {
            return brut
        }
        // Deux caracteres derives du nom : deterministes, donc le groupe
        // garde la meme identite apres redemarrage de l'application.
        val deux = (brut + "XY").take(2)
        return prefixe + deux
    }

    /** Ferme le groupe (l'excavatrice cesse d'etre point d'acces). */
    fun arreterGroupe(onResultat: (Boolean, String?) -> Unit) {
        val m = manager
        val c = channel
        if (m == null || c == null) {
            onResultat(false, "aucun groupe ouvert")
            return
        }
        m.removeGroup(c, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                estGroupeProprietaire = false
                adresseGroupe = null
                infoGroupe = null
                onResultat(true, null)
            }

            override fun onFailure(raison: Int) {
                onResultat(false, "fermeture du groupe refusee (code $raison)")
            }
        })
    }

    /** Etat du lien, tel que la couche applicative l'affiche. */
    fun etat(): Map<String, Any?> = mapOf(
        "disponible" to estDisponible(),
        "groupOwner" to estGroupeProprietaire,
        "groupeForme" to (infoGroupe?.groupFormed ?: false),
        "adresseGroupOwner" to infoGroupe?.groupOwnerAddress?.hostAddress,
        "adresseLocale" to adresseGroupe
    )

    /** Libere le recepteur : a appeler quand la session se termine. */
    fun liberer() {
        recepteur?.let {
            try {
                context.unregisterReceiver(it)
            } catch (e: IllegalArgumentException) {
                // Deja desenregistre : sans importance.
            }
        }
        recepteur = null
        channel = null
    }

    // ------------------------------------------------------- role client

    /**
     * Decouvre les groupes Wi-Fi Direct a portee (mode client : DT, spotter).
     *
     * `discoverPeers` est asynchrone ; la liste n'est disponible qu'apres le
     * callback. On prepare donc l'initialisation du canal et le recepteur, et
     * on rend la liste des pairs deja connus dans `WIFI_P2P_PEERS_CHANGED`.
     *
     * @param onResultat liste de `{nom, adresse}` (nom = nom du device).
     */
    fun decouvrirGroupes(onResultat: (Boolean, String?, List<Map<String, String>>) -> Unit) {
        val m = manager
        if (m == null) {
            onResultat(false, "Wi-Fi Direct indisponible", emptyList())
            return
        }
        if (!aPermissions()) {
            onResultat(false, "Permission Wi-Fi manquante", emptyList())
            return
        }
        if (channel == null) {
            channel = m.initialize(context, Looper.getMainLooper()) {
                Log.w(TAG, "Canal Wi-Fi Direct perdu (client)")
            }
        }
        val c = channel ?: run {
            onResultat(false, "Canal Wi-Fi Direct non initialise", emptyList())
            return
        }
        // Mode decouverte : on ne cree pas de groupe, on ecoute les autres.
        estGroupeProprietaire = false
        enregistrerRecepteur(c)

        m.discoverPeers(c, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                m.requestPeers(c) { liste ->
                    // requestPeers rend un WifiP2pDeviceList, pas une
                    // Collection : on passe par sa deviceList.
                    val peers = liste?.deviceList?.toList() ?: emptyList()
                    pairs = peers
                    onResultat(true, null, decoderPeers(peers))
                }
            }

            override fun onFailure(raison: Int) {
                onResultat(false, "decouverte refusee (code $raison)", emptyList())
            }
        })
    }

    /**
     * Se connecte au groupe [nom] (celui de l'excavatrice).
     *
     * Cherche le pair correspondant dans la derniere decouverte, puis lance
     * `connect`. En Wi-Fi Direct, l'appareil qui se connecte a un Group Owner
     * existant devient client : c'est exactement notre mode DT/spotter.
     */
    fun connecterGroupe(
        nom: String,
        onResultat: (Boolean, String?) -> Unit
    ) {
        val m = manager
        val c = channel
        if (m == null || c == null) {
            onResultat(false, "Wi-Fi Direct non initialise")
            return
        }
        val cible = pairs.firstOrNull { it.deviceName?.startsWith(nom) == true }
            ?: pairs.firstOrNull { it.deviceName?.startsWith(PREFIXE_GROUPE) == true }
        if (cible == null) {
            onResultat(false, "groupe $nom introuvable a portee")
            return
        }
        // API 29+ : `setDeviceAddress` attend un MacAddress, pas une String.
        // `MacAddress.fromString` valide l'adresse de la pile ; une adresse
        // invalide lancerait une IllegalArgumentException, d'ou le try.
        val config = try {
            WifiP2pConfig.Builder()
                .setDeviceAddress(MacAddress.fromString(cible.deviceAddress))
                .setNetworkName(cible.deviceName)
                .setPassphrase(MOT_DE_PASSE)
                .build()
        } catch (e: IllegalArgumentException) {
            onResultat(false, "adresse du pair invalide : ${e.message}")
            return
        }
        m.connect(c, config, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                Log.i(TAG, "Connexion demandee a ${cible.deviceName}")
                onResultat(true, null)
            }

            override fun onFailure(raison: Int) {
                onResultat(false, "connexion refusee (code $raison)")
            }
        })
    }

    /** Oublie un groupe enregistre par le systeme (nettoyage, reconfiguration). */
    fun oublierGroupe(onResultat: (Boolean, String?) -> Unit) {
        val m = manager
        val c = channel
        if (m == null || c == null) {
            onResultat(false, "Wi-Fi Direct non initialise")
            return
        }
        m.removeGroup(c, object : WifiP2pManager.ActionListener {
            override fun onSuccess() = onResultat(true, null)
            override fun onFailure(raison: Int) =
                onResultat(false, "groupe non oublie (code $raison)")
        })
    }

    /** Adresse IP du Group Owner, quand un client est connecte. */
    @SuppressLint("MissingPermission")
    fun adresseGroupOwner(): String? = infoGroupe?.groupOwnerAddress?.hostAddress

    /**
     * En clair : les pairs decouverts, pour la couche applicative.
     * Le nom du device porte l'identite ORE-EXC quand c'est notre excavatrice.
     */
    private fun decoderPeers(peers: Collection<WifiP2pDevice>): List<Map<String, String>> =
        peers.map { device ->
            mapOf(
                "nom" to (device.deviceName ?: ""),
                "adresse" to device.deviceAddress,
                "statut" to statutLisible(device.status)
            )
        }

    private fun statutLisible(statut: Int): String = when (statut) {
        WifiP2pDevice.AVAILABLE -> "disponible"
        WifiP2pDevice.INVITED -> "invite"
        WifiP2pDevice.CONNECTED -> "connecte"
        WifiP2pDevice.FAILED -> "echec"
        WifiP2pDevice.UNAVAILABLE -> "indisponible"
        else -> "inconnu"
    }

    // --------------------------------------------------------------- interne

    private fun aPermissions(): Boolean {
        val permission = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            Manifest.permission.NEARBY_WIFI_DEVICES
        } else {
            Manifest.permission.ACCESS_FINE_LOCATION
        }
        return ContextCompat.checkSelfPermission(context, permission) ==
                PackageManager.PERMISSION_GRANTED
    }

    private fun enregistrerRecepteur(c: WifiP2pManager.Channel) {
        if (recepteur != null) return
        val r = object : BroadcastReceiver() {
            override fun onReceive(ctx: Context, intent: Intent) {
                when (intent.action) {
                    WifiP2pManager.WIFI_P2P_CONNECTION_CHANGED_ACTION -> {
                        manager?.requestConnectionInfo(c) { info ->
                            infoGroupe = info
                            estGroupeProprietaire = info.groupFormed && info.isGroupOwner
                            Log.i(
                                TAG,
                                "Lien Wi-Fi Direct : forme=${info.groupFormed} " +
                                        "owner=${info.isGroupOwner} " +
                                        "adresse=${info.groupOwnerAddress?.hostAddress}"
                            )
                        }
                    }
                    WifiP2pManager.WIFI_P2P_STATE_CHANGED_ACTION -> {
                        val etat = intent.getIntExtra(
                            WifiP2pManager.EXTRA_WIFI_STATE, -1
                        )
                        Log.i(TAG, "Etat Wi-Fi Direct : $etat")
                    }
                }
            }
        }
        val filtre = IntentFilter().apply {
            addAction(WifiP2pManager.WIFI_P2P_STATE_CHANGED_ACTION)
            addAction(WifiP2pManager.WIFI_P2P_CONNECTION_CHANGED_ACTION)
            addAction(WifiP2pManager.WIFI_P2P_THIS_DEVICE_CHANGED_ACTION)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(r, filtre, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            context.registerReceiver(r, filtre)
        }
        recepteur = r
    }

    /** Liste lisible des clients connectes (supervision §21/§22). */
    @SuppressLint("MissingPermission")
    fun clients(onResultat: (List<String>) -> Unit) {
        val m = manager
        val c = channel
        if (m == null || c == null) {
            onResultat(emptyList())
            return
        }
        m.requestGroupInfo(c) { groupe ->
            val noms = groupe?.clientList?.map { device: WifiP2pDevice ->
                device.deviceName ?: device.deviceAddress
            } ?: emptyList()
            onResultat(noms)
        }
    }
}

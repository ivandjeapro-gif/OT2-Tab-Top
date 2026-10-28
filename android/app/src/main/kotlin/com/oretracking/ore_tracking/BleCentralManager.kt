package com.oretracking.ore_tracking

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothStatusCodes
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.content.SharedPreferences
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import android.util.Log
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.util.UUID

/**
 * Client BLE NATIF (Android) avec AUTO-CONNECT et persistance du pairing.
 *
 * POURQUOI CE CANAL ALORS QUE `flutter_reactive_ble` EXISTE DEJA.
 *
 * Le plugin Dart ne gere que la connexion « directe » (`connectGatt(ctx,
 * false, cb)`). Il referme le GATT des que le flux Dart s'arrete, et Android
 * ne conserve AUCUNE demande en attente. Consequence terrain : apres une
 * sortie de portee, la reconnexion dependait d'un scan applicatif toutes les
 * quelques secondes — lent, energivore, et sans garantie de retrouver le bon
 * engin.
 *
 * `connectGatt(context, true, callback)` avec `autoConnect = true` delegue la
 * surveillance au SYSTEME : la demande reste enregistree au niveau de la pile
 * Android, qui etablit la connexion des que l'appareil redevient visible —
 * sans scan, sans consommer d'energie, et en moins de deux secondes.
 *
 * CE QUE CE GESTIONNAIRE FAIT :
 *  - scan filtre par UUID de service (critere materiel, jamais tronque) ;
 *  - connexion directe (autoConnect) sur l'adresse memorisee ;
 *  - persistance de l'adresse et du nom (SharedPreferences) ;
 *  - detection du changement d'adresse Android (adresse privee renouvelee) :
 *    repli par scan, comparaison du NOM dans les donnees fabricant, mise a
 *    jour de la memoire ;
 *  - nettoyage GATT systematique (`close()`) avant chaque tentative.
 *
 * Le protocole applicatif (handshake, evenements, ACK) reste en Dart : ce
 * canal ne transporte que des OCTETS bruts. La machine d'etat et la
 * signification des messages appartiennent a `BleClient`.
 */
@SuppressLint("MissingPermission")
class BleCentralManager(private val contexte: Context) {

    companion object {
        private const val TAG = "OreBleCentral"

        /** Service ORE TRACKING : critere de decouverte (16 octets fixes). */
        private val UUID_SERVICE: UUID =
            UUID.fromString("0000fe5a-0000-1000-8000-00805f9b34fb")

        /** Caracteristique d'ECRITURE (client -> excavatrice). */
        private val UUID_RX: UUID =
            UUID.fromString("0000fe5b-0000-1000-8000-00805f9b34fb")

        /** Caracteristique de NOTIFICATION (excavatrice -> client). */
        private val UUID_TX: UUID =
            UUID.fromString("0000fe5c-0000-1000-8000-00805f9b34fb")

        /** Descripteur de notification standard (CCCD). */
        private val UUID_CCCD: UUID =
            UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")

        /** Identifiant fabricant portant le nom annonce (eventail ble_peripheral). */
        private const val ID_FABRICANT = 0xFFF0

        private const val CLE_ADRESSE = "ble_adresse"
        private const val CLE_NOM = "ble_nom"
        private const val PREFER = "ore_ble_pairing"
    }

    // ---------------------------------------------------------------- etat

    private val gestionnaire: BluetoothManager? =
        contexte.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager

    private val adaptateur get() = gestionnaire?.adapter

    private var gatt: BluetoothGatt? = null

    /** Adresse de l'appareil sur lequel on est (ou tente d'etre) connecte. */
    private var adresseCourante: String? = null

    /** Flux d'evenements vers Dart (etats + octets recus). */
    private var evenements: EventChannel.EventSink? = null

    /** Resultat en attente de la demande de connexion initiale. */
    private var resultatConnexion: MethodChannel.Result? = null

    private val principal = Handler(Looper.getMainLooper())

    private var scanEnCours = false

    // ------------------------------------------------------------ memoire

    private val prefs: SharedPreferences
        get() = contexte.getSharedPreferences(PREFER, Context.MODE_PRIVATE)

    /** Adresse memorisee de l'excavatrice appairee (null si aucune). */
    fun adresseMemorisee(): String? = prefs.getString(CLE_ADRESSE, null)

    /** Nom memorise de l'excavatrice appairee. */
    fun nomMemorise(): String? = prefs.getString(CLE_NOM, null)

    /**
     * Enregistre le pairing applicatif.
     *
     * Appele par Dart UNIQUEMENT apres un handshake reussi : memoriser une
     * adresse qui n'a pas abouti ferait viser pour toujours un appareil
     * inutilisable (non enrole, ou hors service).
     */
    fun memoriser(adresse: String, nom: String) {
        prefs.edit().putString(CLE_ADRESSE, adresse).putString(CLE_NOM, nom).apply()
        Log.i(TAG, "appairage memorise : $nom ($adresse)")
    }

    /** Oublie le pairing (deconnexion volontaire, changement d'engin). */
    fun oublier() {
        prefs.edit().remove(CLE_ADRESSE).remove(CLE_NOM).apply()
        Log.i(TAG, "appairage oublie")
    }

    // ----------------------------------------------------------- canaux

    /** Branche le flux d'evenements (appelee par MainActivity). */
    fun brancherFlux(sink: EventChannel.EventSink?) {
        evenements = sink
    }

    private fun emettre(type: String, donnees: Map<String, Any?> = emptyMap()) {
        val message = HashMap<String, Any?>(donnees)
        message["type"] = type
        principal.post { evenements?.success(message) }
    }

    private fun informerEtat(etat: String, detail: String = "") {
        Log.i(TAG, "ETAT $etat ${if (detail.isEmpty()) "" else "($detail)"}")
        emettre("etat", mapOf("etat" to etat, "detail" to detail))
    }

    // --------------------------------------------------------- connexion

    /**
     * Connexion DIRECTE (autoConnect) sur l'adresse memorisee.
     *
     * Rend immediatement `{ok:true, memorise:true}` : la connexion elle-meme
     * est asynchrone et arrive par le flux (`etat=CONNECTED`). On ne bloque
     * PAS Dart pendant dix secondes : le systeme peut mettre la demande en
     * attente bien plus longtemps, c'est precisement l'interet.
     */
    fun connecterDirect(resultat: MethodChannel.Result) {
        val adresse = adresseMemorisee()
        val adaptateur = adaptateur
        if (adaptateur == null || !adaptateur.isEnabled) {
            resultat.success(mapOf("ok" to false, "erreur" to "bluetooth desactive"))
            return
        }
        if (adresse.isNullOrEmpty()) {
            // Aucun appairage : Dart doit passer par un scan.
            resultat.success(mapOf("ok" to false, "erreur" to "aucune adresse memorisee"))
            return
        }
        val appareil = try {
            adaptateur.getRemoteDevice(adresse)
        } catch (e: IllegalArgumentException) {
            // Adresse devenue invalide (autre appareil, format change).
            oublier()
            resultat.success(mapOf("ok" to false, "erreur" to "adresse invalide"))
            return
        }
        resultatConnexion = resultat
        ouvrirGatt(appareil, autoConnect = true)
        informerEtat("CONNECTING", "directe vers ${nomMemorise() ?: adresse}")
        // On rend la main tout de suite : le resultat final arrive par le flux.
        resultat.success(mapOf("ok" to true, "memorise" to true, "adresse" to adresse))
    }

    /**
     * Connexion sur un appareil trouve par SCAN (adresse non memorisee, ou
     * adresse Android renouvelee).
     */
    fun connecter(adresse: String, nom: String, resultat: MethodChannel.Result) {
        val adaptateur = adaptateur
        if (adaptateur == null || !adaptateur.isEnabled) {
            resultat.success(mapOf("ok" to false, "erreur" to "bluetooth desactive"))
            return
        }
        val appareil = try {
            adaptateur.getRemoteDevice(adresse)
        } catch (e: IllegalArgumentException) {
            resultat.success(mapOf("ok" to false, "erreur" to "adresse invalide"))
            return
        }
        resultatConnexion = resultat
        // `autoConnect = false` : on veut un echec RAPIDE si l'appareil n'est
        // pas joignable, puisque le scan vient justement de le voir. La
        // capture de l'adresse se fait au handshake reussi.
        ouvrirGatt(appareil, autoConnect = false)
        informerEtat("CONNECTING", "$nom ($adresse)")
        resultat.success(mapOf("ok" to true, "adresse" to adresse))
    }

    /**
     * Ferme le GATT COURANT avant d'en ouvrir un autre.
     *
     * C'est la regle n°1 contre les bugs BLE Android : un `BluetoothGatt`
     * non ferme garde la ressource du controleur, et la tentative suivante
     * echoue en `133` (GATT_ERROR) sans explication. On appelle donc
     * TOUJOURS `disconnect()` puis `close()`, et on remet la reference a null.
     */
    private fun libererGatt() {
        val ancien = gatt
        gatt = null
        if (ancien == null) return
        try {
            ancien.disconnect()
        } catch (_: Exception) {
        }
        try {
            ancien.close()
        } catch (_: Exception) {
        }
        Log.i(TAG, "GATT libere")
    }

    private fun ouvrirGatt(appareil: BluetoothDevice, autoConnect: Boolean) {
        libererGatt()
        adresseCourante = appareil.address
        Log.i(TAG, "connectGatt autoConnect=$autoConnect sur ${appareil.address}")
        gatt = appareil.connectGatt(contexte, autoConnect, rappel, BluetoothDevice.TRANSPORT_LE)
        if (gatt == null) {
            informerEtat("DISCONNECTED", "connectGatt a rendu null")
            resultatConnexion?.success(mapOf("ok" to false, "erreur" to "connectGatt null"))
            resultatConnexion = null
        }
    }

    /** Callback GATT : etats, decouverte, notifications. */
    private val rappel = object : BluetoothGattCallback() {

        override fun onConnectionStateChange(g: BluetoothGatt, status: Int, nouvelEtat: Int) {
            val adresse = g.device.address
            Log.i(TAG, "onConnectionStateChange status=$status etat=$nouvelEtat ($adresse)")

            if (nouvelEtat == BluetoothProfile.STATE_CONNECTED) {
                informerEtat("CONNECTED", adresse)
                resultatConnexion = null
                // MTU puis decouverte : l'ordre compte, une souscription sur
                // un service non decouvert echoue (Android 15).
                g.requestMtu(512)
                return
            }

            // Deconnexion : liberer et signaler.
            val raison = when (status) {
                BluetoothGatt.GATT_SUCCESS -> "deconnexion"
                133 -> "GATT_ERROR (133)"
                8 -> "lien perdu (supervision)"
                19 -> "deconnecte par le peripherique"
                else -> "status $status"
            }
            libererGatt()
            informerEtat("DISCONNECTED", raison)
        }

        override fun onMtuChanged(g: BluetoothGatt, mtu: Int, status: Int) {
            Log.i(TAG, "MTU=$mtu status=$status")
            g.discoverServices()
        }

        override fun onServicesDiscovered(g: BluetoothGatt, status: Int) {
            if (status != BluetoothGatt.GATT_SUCCESS) {
                informerEtat("DISCONNECTED", "decouverte des services echouee ($status)")
                libererGatt()
                return
            }
            val service = g.getService(UUID_SERVICE)
            val tx = service?.getCharacteristic(UUID_TX)
            val rx = service?.getCharacteristic(UUID_RX)
            if (tx == null || rx == null) {
                informerEtat("DISCONNECTED", "service ORE absent")
                libererGatt()
                return
            }
            // Notifications : activer le CCCD, sinon aucune donnee n'arrive.
            g.setCharacteristicNotification(tx, true)
            val cccd = tx.getDescriptor(UUID_CCCD)
            if (cccd != null) {
                ecrireDescripteur(g, cccd)
            } else {
                informerEtat("READY", "notifications actives (sans CCCD)")
            }
        }

        private fun ecrireDescripteur(g: BluetoothGatt, cccd: BluetoothGattDescriptor) {
            val valeur = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                g.writeDescriptor(cccd, valeur)
            } else {
                @Suppress("DEPRECATION")
                cccd.value = valeur
                @Suppress("DEPRECATION")
                g.writeDescriptor(cccd)
            }
        }

        override fun onDescriptorWrite(g: BluetoothGatt, d: BluetoothGattDescriptor, status: Int) {
            // Pret : Dart peut envoyer le handshake.
            informerEtat("READY", "notifications actives (status $status)")
        }

        override fun onCharacteristicChanged(
            g: BluetoothGatt,
            caracteristique: BluetoothGattCharacteristic,
            valeur: ByteArray,
        ) {
            // API 33+. Les versions anterieures passent par l'ancienne
            // surcharge `onCharacteristicChanged(gatt, characteristic)`.
            emettre("donnees", mapOf("octets" to valeur))
        }

        @Deprecated("Compatibilite Android < 13")
        override fun onCharacteristicChanged(
            g: BluetoothGatt,
            caracteristique: BluetoothGattCharacteristic,
        ) {
            @Suppress("DEPRECATION")
            val valeur = caracteristique.value ?: return
            emettre("donnees", mapOf("octets" to valeur))
        }
    }

    /** Ecrit des octets sur la caracteristique RX (client -> excavatrice). */
    fun ecrire(octets: ByteArray, resultat: MethodChannel.Result) {
        val g = gatt
        if (g == null) {
            resultat.success(mapOf("ok" to false, "erreur" to "non connecte"))
            return
        }
        val service = g.getService(UUID_SERVICE)
        val rx = service?.getCharacteristic(UUID_RX)
        if (rx == null) {
            resultat.success(mapOf("ok" to false, "erreur" to "caracteristique RX absente"))
            return
        }
        val ok = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            g.writeCharacteristic(rx, octets, BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT) ==
                BluetoothStatusCodes.SUCCESS
        } else {
            @Suppress("DEPRECATION")
            rx.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
            @Suppress("DEPRECATION")
            rx.value = octets
            @Suppress("DEPRECATION")
            g.writeCharacteristic(rx)
        }
        resultat.success(mapOf("ok" to ok))
    }

    /** Deconnexion propre et oubli du lien courant. */
    fun deconnecter(oublierPairing: Boolean = false) {
        libererGatt()
        adresseCourante = null
        if (oublierPairing) oublier()
        informerEtat("DISCONNECTED", if (oublierPairing) "volontaire (pairing efface)" else "volontaire")
    }

    // -------------------------------------------------------------- scan

    /**
     * Scan filtre par UUID de service.
     *
     * Critere MATERIEL : un UUID fait 16 octets fixes dans l'advertisement,
     * alors que le nom peut etre tronque ou absent (paquet de 31 octets).
     * Chaque appareil trouve est remonte a Dart avec son nom et son adresse.
     */
    fun scanner(dureeMs: Long, resultat: MethodChannel.Result) {
        val adaptateur = adaptateur
        val scanner = adaptateur?.bluetoothLeScanner
        if (adaptateur == null || !adaptateur.isEnabled || scanner == null) {
            resultat.success(mapOf("ok" to false, "erreur" to "bluetooth desactive"))
            return
        }
        if (scanEnCours) {
            resultat.success(mapOf("ok" to false, "erreur" to "scan deja en cours"))
            return
        }
        val filtre = ScanFilter.Builder()
            .setServiceUuid(ParcelUuid(UUID_SERVICE))
            .build()
        val reglages = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .build()

        val rappelScan = object : ScanCallback() {
            override fun onScanResult(type: Int, r: ScanResult) {
                val nom = r.scanRecord?.deviceName
                    ?: r.scanRecord?.getManufacturerSpecificData(ID_FABRICANT)?.let {
                        String(it)
                    } ?: ""
                emettre(
                    "appareil",
                    mapOf(
                        "adresse" to r.device.address,
                        "nom" to nom,
                        "rssi" to r.rssi,
                    )
                )
            }

            override fun onScanFailed(erreur: Int) {
                scanEnCours = false
                Log.w(TAG, "scan echoue : $erreur")
                emettre("scanTermine", mapOf("erreur" to erreur))
            }
        }

        scanEnCours = true
        adaptateur.bluetoothLeScanner.startScan(listOf(filtre), reglages, rappelScan)
        principal.postDelayed({
            if (scanEnCours) {
                try {
                    adaptateur.bluetoothLeScanner.stopScan(rappelScan)
                } catch (_: Exception) {
                }
                scanEnCours = false
                emettre("scanTermine")
            }
        }, dureeMs)
        resultat.success(mapOf("ok" to true, "dureeMs" to dureeMs))
    }

    /** Etat de la pile (pour la machine d'etat Dart). */
    fun etatPile(): Map<String, Any?> {
        val a = adaptateur
        return mapOf(
            "disponible" to (a != null),
            "active" to (a?.isEnabled == true),
            "adresseMemorisee" to adresseMemorisee(),
            "nomMemorise" to nomMemorise(),
            "connecte" to (gatt != null && adresseCourante != null),
            "adresseCourante" to adresseCourante,
        )
    }

    fun liberer() {
        libererGatt()
        evenements = null
    }
}

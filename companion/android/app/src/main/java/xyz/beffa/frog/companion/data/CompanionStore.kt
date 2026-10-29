package xyz.beffa.frog.companion.data

import android.content.Context
import android.content.SharedPreferences
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import xyz.beffa.frog.companion.protocol.PairingCode
import java.security.KeyStore
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

data class PairedMac(
    val id: UUID,
    val name: String,
    val secret: ByteArray,
    val port: Int,
    /** Last successful host first, then the hosts from the QR code. */
    val hosts: List<String>,
)

/** Small persistent state. The pairing secret is wrapped with a non-exportable Keystore key. */
class CompanionStore(context: Context) {
    private val prefs: SharedPreferences = context.getSharedPreferences("frog_companion", Context.MODE_PRIVATE)

    val deviceId: UUID by lazy {
        prefs.getString(KEY_DEVICE_ID, null)?.let { runCatching { UUID.fromString(it) }.getOrNull() }
            ?: UUID.randomUUID().also { prefs.edit().putString(KEY_DEVICE_ID, it.toString()).apply() }
    }

    var onboardingDone: Boolean
        get() = prefs.getBoolean(KEY_ONBOARDED, false)
        set(value) = prefs.edit().putBoolean(KEY_ONBOARDED, value).apply()

    fun pairedMac(): PairedMac? {
        val id = prefs.getString(KEY_MAC_ID, null)?.let { runCatching { UUID.fromString(it) }.getOrNull() } ?: return null
        val wrapped = prefs.getString(KEY_SECRET, null) ?: return null
        val secret = runCatching { unwrap(Base64.decode(wrapped, Base64.NO_WRAP)) }.getOrNull() ?: return null
        return PairedMac(
            id = id,
            name = prefs.getString(KEY_MAC_NAME, null) ?: "Mac",
            secret = secret,
            port = prefs.getInt(KEY_PORT, 47321),
            hosts = prefs.getString(KEY_HOSTS, "").orEmpty().split(',').filter { it.isNotBlank() },
        )
    }

    fun savePairing(code: PairingCode) {
        prefs.edit()
            .putString(KEY_MAC_ID, code.macId.toString().lowercase())
            .putString(KEY_MAC_NAME, code.macName)
            .putString(KEY_SECRET, Base64.encodeToString(wrap(code.secret), Base64.NO_WRAP))
            .putInt(KEY_PORT, code.port)
            .putString(KEY_HOSTS, code.hosts.joinToString(","))
            .remove(KEY_RECEIVED_IDS)
            .commit()
    }

    fun updateMacName(name: String) {
        if (name.isNotBlank()) prefs.edit().putString(KEY_MAC_NAME, name).apply()
    }

    /** Remembers a host and port that worked, ahead of the QR hosts. */
    fun rememberEndpoint(host: String, port: Int) {
        val current = prefs.getString(KEY_HOSTS, "").orEmpty().split(',').filter { it.isNotBlank() }
        val updated = (listOf(host) + current.filter { it != host }).take(6)
        prefs.edit().putString(KEY_HOSTS, updated.joinToString(",")).putInt(KEY_PORT, port).apply()
    }

    fun forgetPairing() {
        prefs.edit()
            .remove(KEY_MAC_ID).remove(KEY_MAC_NAME).remove(KEY_SECRET)
            .remove(KEY_PORT).remove(KEY_HOSTS).remove(KEY_RECEIVED_IDS)
            .commit()
    }

    /** The last 64 clip IDs received, oldest first. */
    fun receivedIds(): List<String> =
        prefs.getString(KEY_RECEIVED_IDS, "").orEmpty().split(',').filter { it.isNotBlank() }

    fun saveReceivedIds(ids: List<String>) {
        prefs.edit().putString(KEY_RECEIVED_IDS, ids.joinToString(",")).apply()
    }

    private fun key(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (ks.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }
        val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        gen.init(
            KeyGenParameterSpec.Builder(KEY_ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build(),
        )
        return gen.generateKey()
    }

    private fun wrap(plain: ByteArray): ByteArray {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key())
        return cipher.iv + cipher.doFinal(plain)
    }

    private fun unwrap(blob: ByteArray): ByteArray {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, blob, 0, 12))
        return cipher.doFinal(blob, 12, blob.size - 12)
    }

    private companion object {
        const val KEY_ALIAS = "frog-companion-pairing"
        const val KEY_DEVICE_ID = "device_id"
        const val KEY_ONBOARDED = "onboarded"
        const val KEY_MAC_ID = "mac_id"
        const val KEY_MAC_NAME = "mac_name"
        const val KEY_SECRET = "mac_secret"
        const val KEY_PORT = "mac_port"
        const val KEY_HOSTS = "mac_hosts"
        const val KEY_RECEIVED_IDS = "received_ids"
    }
}

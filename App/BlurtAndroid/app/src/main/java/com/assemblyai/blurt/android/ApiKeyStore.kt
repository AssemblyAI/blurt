package com.assemblyai.blurt.android

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * The user's AssemblyAI API key — pasted, or minted by Sign in with AssemblyAI
 * (the sign-in stores its key here too, so dictation reads one place).
 */
object ApiKeyStore {
    private const val FIELD = "api_key"

    fun load(context: Context): String? = SecureStore.read(context, FIELD)

    fun save(context: Context, apiKey: String) = SecureStore.write(context, FIELD, apiKey.trim())

    fun clear(context: Context) = SecureStore.write(context, FIELD, null)
}

/**
 * Secrets encrypted with an AES key that lives in the Android Keystore (the
 * counterpart of the Keychain the Mac and iPhone use), so the preferences file
 * only ever holds ciphertext.
 */
object SecureStore {
    private const val KEY_ALIAS = "blurt-api-key"
    private const val PREFS = "blurt"
    private const val TRANSFORMATION = "AES/GCM/NoPadding"

    fun read(context: Context, field: String): String? {
        val stored = prefs(context).getString(field, null) ?: return null
        return try {
            val (iv, ciphertext) = stored.split(":").map { Base64.decode(it, Base64.NO_WRAP) }
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.DECRYPT_MODE, secretKey(), GCMParameterSpec(128, iv))
            String(cipher.doFinal(ciphertext))
        } catch (e: Exception) {
            // A Keystore key lost to a reset or a corrupt entry: as if never saved.
            null
        }
    }

    /** Stores [value] encrypted, or removes the field when it's null. */
    fun write(context: Context, field: String, value: String?) {
        if (value == null) {
            prefs(context).edit().remove(field).apply()
            return
        }
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, secretKey())
        val ciphertext = cipher.doFinal(value.toByteArray())
        val encoded = listOf(cipher.iv, ciphertext).joinToString(":") {
            Base64.encodeToString(it, Base64.NO_WRAP)
        }
        prefs(context).edit().putString(field, encoded).apply()
    }

    private fun prefs(context: Context) =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private fun secretKey(): SecretKey {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (keyStore.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .build(),
        )
        return generator.generateKey()
    }
}

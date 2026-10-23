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
 * The user's AssemblyAI API key, encrypted with an AES key that lives in the
 * Android Keystore (the counterpart of the Keychain the Mac and iPhone use), so
 * the preferences file only ever holds ciphertext.
 */
object ApiKeyStore {
    private const val KEY_ALIAS = "blurt-api-key"
    private const val PREFS = "blurt"
    private const val FIELD = "api_key"
    private const val TRANSFORMATION = "AES/GCM/NoPadding"

    fun load(context: Context): String? {
        val stored = prefs(context).getString(FIELD, null) ?: return null
        return try {
            val (iv, ciphertext) = stored.split(":").map { Base64.decode(it, Base64.NO_WRAP) }
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.DECRYPT_MODE, secretKey(), GCMParameterSpec(128, iv))
            String(cipher.doFinal(ciphertext))
        } catch (e: Exception) {
            // A Keystore key lost to a reset or a corrupt entry: ask for the key again.
            null
        }
    }

    fun save(context: Context, apiKey: String) {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, secretKey())
        val ciphertext = cipher.doFinal(apiKey.trim().toByteArray())
        val encoded = listOf(cipher.iv, ciphertext).joinToString(":") {
            Base64.encodeToString(it, Base64.NO_WRAP)
        }
        prefs(context).edit().putString(FIELD, encoded).apply()
    }

    fun clear(context: Context) {
        prefs(context).edit().remove(FIELD).apply()
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

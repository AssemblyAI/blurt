package com.assemblyai.blurt.android

import android.net.Uri
import android.util.Base64
import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONException
import org.json.JSONObject
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.security.MessageDigest
import java.security.SecureRandom
import java.time.Instant
import java.time.format.DateTimeParseException

/**
 * Sign in with AssemblyAI's wire side: a port of `Sources/AssemblyAI/OAuth`
 * (`OAuthAuthorization` and `OAuthClient`), whose comments say why each step is
 * shaped the way it is. Authorization code with PKCE against the dashboard's
 * consent page; the access token is then traded for the connection's own API
 * key, which is what dictation uses.
 */
class OAuthConfig(
    val clientId: String,
    val authorizeUrl: String,
    val tokenUrl: String,
    apiOrigin: String,
    /** The dictation host a signed-in key belongs to; null means production. */
    val dictationOrigin: String?,
) {
    val apiKeyUrl = apiOrigin.trimEnd('/') + "/api/v2/oauth/api-key"
    val revokeUrl = apiOrigin.trimEnd('/') + "/api/v2/oauth/api-key/revoke"

    companion object {
        /**
         * Blurt's redirect, the same one the Mac uses, so the Connected App
         * already lists it. The manifest routes it to [MainActivity].
         */
        const val REDIRECT_URI = "com.assemblyai.blurt://oauth/callback"

        /** `aai:api` is what the key exchange checks for; `offline_access` buys the refresh token. */
        const val SCOPES = "openid email offline_access aai:api"

        /**
         * This build's sign-in, or null when any value is missing or not https
         * (see `blurt.oauth.*` in the README). Builds without it offer only the
         * paste-a-key path, like the Mac's release builds.
         */
        val current: OAuthConfig? by lazy {
            val urls = listOf(BuildConfig.OAUTH_AUTHORIZE_URL, BuildConfig.OAUTH_TOKEN_URL, BuildConfig.OAUTH_API_ORIGIN)
            if (BuildConfig.OAUTH_CLIENT_ID.isBlank() || urls.any { !it.startsWith("https://") }) {
                null
            } else {
                OAuthConfig(
                    clientId = BuildConfig.OAUTH_CLIENT_ID,
                    authorizeUrl = BuildConfig.OAUTH_AUTHORIZE_URL,
                    tokenUrl = BuildConfig.OAUTH_TOKEN_URL,
                    apiOrigin = BuildConfig.OAUTH_API_ORIGIN,
                    dictationOrigin = BuildConfig.OAUTH_DICTATION_ORIGIN.takeIf { it.startsWith("https://") },
                )
            }
        }
    }
}

/** One sign-in attempt: the consent page URL, and the verifier and state its callback is checked against. */
class OAuthAuthorization(val codeVerifier: String, val state: String) {

    sealed class CallbackError(message: String?) : Exception(message) {
        /** The member declined on the consent page. */
        object Denied : CallbackError("denied")

        /** Not this attempt's redirect: stale or forged. */
        object StateMismatch : CallbackError("state mismatch")

        class Failed(reason: String?) : CallbackError(reason)
    }

    fun url(config: OAuthConfig): Uri =
        Uri.parse(config.authorizeUrl).buildUpon()
            .appendQueryParameter("client_id", config.clientId)
            .appendQueryParameter("redirect_uri", OAuthConfig.REDIRECT_URI)
            .appendQueryParameter("response_type", "code")
            .appendQueryParameter("scope", OAuthConfig.SCOPES)
            .appendQueryParameter("state", state)
            .appendQueryParameter("code_challenge", challenge())
            .appendQueryParameter("code_challenge_method", "S256")
            .build()

    /** The authorization code from the redirect, after checking it answers this attempt. */
    fun code(callback: Uri): String {
        // `state` first: an error redirect that isn't ours says nothing about this attempt.
        if (callback.getQueryParameter("state") != state) throw CallbackError.StateMismatch
        callback.getQueryParameter("error")?.let { error ->
            throw if (error == "access_denied") {
                CallbackError.Denied
            } else {
                CallbackError.Failed(callback.getQueryParameter("error_description") ?: error)
            }
        }
        return callback.getQueryParameter("code")?.takeIf { it.isNotBlank() }
            ?: throw CallbackError.Failed(null)
    }

    private fun challenge(): String =
        base64Url(MessageDigest.getInstance("SHA-256").digest(codeVerifier.toByteArray()))

    companion object {
        fun create(): OAuthAuthorization =
            // 32 bytes → a 43-character verifier, the shortest RFC 7636 allows.
            OAuthAuthorization(base64Url(randomBytes(32)), base64Url(randomBytes(16)))

        private fun randomBytes(count: Int) = ByteArray(count).also { SecureRandom().nextBytes(it) }

        private fun base64Url(bytes: ByteArray): String =
            Base64.encodeToString(bytes, Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP)
    }
}

/** The token endpoint and the API-key exchange and revoke routes. */
class OAuthClient(private val config: OAuthConfig) {

    class Tokens(val accessToken: String, val refreshToken: String?, val idToken: String?) {
        /** The ID token's `email` claim. Read without verifying: it only labels the account row. */
        val email: String?
            get() {
                val payload = idToken?.split(".")?.getOrNull(1) ?: return null
                return try {
                    val json = String(Base64.decode(payload, Base64.URL_SAFE or Base64.NO_PADDING))
                    JSONObject(json).optString("email").takeIf { it.isNotBlank() }
                } catch (e: IllegalArgumentException) {
                    null
                } catch (e: JSONException) {
                    null
                }
            }
    }

    class ConnectionKey(val apiKey: String, val expiresAt: Instant?, val rotatesAt: Instant?)

    sealed class Failure(message: String?) : IOException(message) {
        /** A credential the server refused (an expired code, a revoked grant). */
        object Rejected : Failure("rejected")

        /** The exchange refused this member; carries the server's reason. */
        class Forbidden(val reason: String?) : Failure(reason)

        /** Couldn't reach AssemblyAI, or it failed in a way that says nothing about the credential. */
        object Unreachable : Failure("unreachable")
    }

    suspend fun tokens(authorization: OAuthAuthorization, code: String): Tokens = tokenRequest(
        mapOf(
            "grant_type" to "authorization_code",
            "client_id" to config.clientId,
            "code" to code,
            "code_verifier" to authorization.codeVerifier,
            "redirect_uri" to OAuthConfig.REDIRECT_URI,
        ),
    )

    suspend fun refresh(refreshToken: String): Tokens = tokenRequest(
        mapOf(
            "grant_type" to "refresh_token",
            "client_id" to config.clientId,
            "refresh_token" to refreshToken,
        ),
    )

    suspend fun apiKey(accessToken: String): ConnectionKey {
        val (status, body) = send(config.apiKeyUrl, bearer = accessToken)
        when (status) {
            in 200..299 -> {
                val json = parse(body) ?: throw Failure.Unreachable
                val key = json.optString("api_key").takeIf { it.isNotBlank() } ?: throw Failure.Unreachable
                return ConnectionKey(key, date(json, "api_key_expires_at"), date(json, "api_key_rotates_at"))
            }
            401 -> throw refusal(config.apiKeyUrl, status, body, Failure.Rejected)
            403 -> throw refusal(config.apiKeyUrl, status, body, Failure.Forbidden(explanation(body)))
            else -> throw refusal(config.apiKeyUrl, status, body, Failure.Unreachable)
        }
    }

    suspend fun revoke(accessToken: String) {
        val (status, body) = send(config.revokeUrl, bearer = accessToken)
        when (status) {
            in 200..299 -> return
            401 -> throw refusal(config.revokeUrl, status, body, Failure.Rejected)
            // 503 is the server saying the grant revoke failed: the grant is
            // still live, so this must not look like a sign-out.
            else -> throw refusal(config.revokeUrl, status, body, Failure.Unreachable)
        }
    }

    private suspend fun tokenRequest(fields: Map<String, String>): Tokens {
        val form = fields.entries.sortedBy { it.key }
            .joinToString("&") { (key, value) -> "$key=${URLEncoder.encode(value, "UTF-8")}" }
        val (status, body) = send(config.tokenUrl, form = form)
        when (status) {
            in 200..299 -> {
                val json = parse(body) ?: throw Failure.Unreachable
                val access = json.optString("access_token").takeIf { it.isNotBlank() } ?: throw Failure.Unreachable
                return Tokens(access, json.nonBlank("refresh_token"), json.nonBlank("id_token"))
            }
            // RFC 6749 §5.2: a refused grant is a 400 or 401. Anything else
            // says nothing about the credential.
            400, 401 -> throw refusal(config.tokenUrl, status, body, Failure.Rejected)
            else -> throw refusal(config.tokenUrl, status, body, Failure.Unreachable)
        }
    }

    private suspend fun send(url: String, bearer: String? = null, form: String? = null): Pair<Int, String> =
        withContext(Dispatchers.IO) {
            try {
                val connection = (URL(url).openConnection() as HttpURLConnection).apply {
                    requestMethod = "POST"
                    connectTimeout = 15_000
                    readTimeout = 30_000
                    setRequestProperty("Accept", "application/json")
                    setRequestProperty("User-Agent", "Blurt-Android/${BuildConfig.VERSION_NAME}")
                    bearer?.let { setRequestProperty("Authorization", "Bearer $it") }
                    doOutput = true
                    if (form != null) setRequestProperty("Content-Type", "application/x-www-form-urlencoded")
                }
                try {
                    connection.outputStream.use { it.write((form ?: "").toByteArray()) }
                    val status = connection.responseCode
                    val stream = if (status in 200..299) connection.inputStream else connection.errorStream
                    status to stream?.bufferedReader()?.use { it.readText() }.orEmpty()
                } finally {
                    connection.disconnect()
                }
            } catch (e: IOException) {
                throw Failure.Unreachable
            }
        }

    /** Logs a refused call's path, status and the server's own reason — never a token. */
    private fun refusal(url: String, status: Int, body: String, failure: Failure): Failure {
        val json = parse(body)
        val reason = listOf("error", "error_description", "detail")
            .mapNotNull { key -> json?.nonBlank(key)?.let { "$key=$it" } }
            .joinToString(" ").ifEmpty { "-" }
        Log.e("BlurtAccount", "${Uri.parse(url).path} -> $status: $reason")
        return failure
    }

    private fun explanation(body: String): String? =
        parse(body)?.let { it.nonBlank("error_description") ?: it.nonBlank("detail") }

    private fun parse(body: String): JSONObject? =
        try {
            JSONObject(body)
        } catch (e: JSONException) {
            null
        }

    private fun JSONObject.nonBlank(key: String): String? =
        if (isNull(key)) null else optString(key).takeIf { it.isNotBlank() }

    private fun date(json: JSONObject, key: String): Instant? =
        json.nonBlank(key)?.let {
            try {
                Instant.parse(it)
            } catch (e: DateTimeParseException) {
                null
            }
        }
}

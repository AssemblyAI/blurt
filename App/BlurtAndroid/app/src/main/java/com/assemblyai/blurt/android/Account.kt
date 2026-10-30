package com.assemblyai.blurt.android

import android.content.Context
import android.net.Uri
import android.util.Log
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.json.JSONException
import org.json.JSONObject
import java.time.Duration
import java.time.Instant

/**
 * "Sign in with AssemblyAI", the alternative to pasting a key: a port of
 * `Sources/BlurtEngine/Account/AssemblyAIAccount.swift` and `SignInSession.swift`.
 *
 * The member approves Blurt on AssemblyAI's consent page; Blurt trades the
 * access token for the connection's own API key and stores it exactly where a
 * pasted key goes ([ApiKeyStore]), so dictation reads one place. What signing
 * in adds is renewal (a refresh and an exchange when the key is due, which
 * also picks up a rotated key) and a real sign-out, which ends the connection
 * server-side.
 *
 * The Mac renews on a timer. An Android app can't keep one running, so this
 * renews when the app opens and when the bubble starts a dictation, and at
 * once when dictation reports the key was refused.
 */
object Account {

    sealed class Status {
        object SignedOut : Status()
        class SignedIn(val email: String?) : Status()
    }

    /** How a sign-in attempt ended. */
    sealed class Outcome {
        object SignedIn : Outcome()
        object Cancelled : Outcome()
        class Failed(val message: String) : Outcome()
    }

    private const val SESSION = "sign_in_session"
    private const val PENDING = "sign_in_pending"
    private const val TAG = "BlurtAccount"

    /** Renew this long before the key expires, when the server gives no rotation time. */
    private val expiryMargin = Duration.ofDays(2)

    /** When the server gives neither expiry nor rotation: renew daily. */
    private val unknownExpiry = Duration.ofDays(1)

    /** A rejected key renews at once, but no more often than this. */
    private val rejectedKeyRenewalSpacing = Duration.ofMinutes(15)

    private val config = OAuthConfig.current
    private val client = config?.let { OAuthClient(it) }
    private val renewal = Mutex()
    private var lastForcedRenewal: Instant? = null

    /**
     * Bumped whenever the stored session is replaced or dropped. A renewal that
     * wakes from the network to a different generation writes nothing, or it
     * would bring back a session the user just ended.
     */
    @Volatile private var generation = 0

    /** Whether this build has sign-in configured. Without it, only the paste-a-key path shows. */
    val isAvailable: Boolean get() = config != null

    private val _status = MutableStateFlow<Status>(Status.SignedOut)
    val status: StateFlow<Status> = _status

    /** Re-reads the stored session; call when the account UI appears. */
    fun refreshStatus(context: Context) {
        _status.value = load(context)?.let { Status.SignedIn(it.email) } ?: Status.SignedOut
    }

    /**
     * Where dictation should go: a sandbox sign-in's keys only work against
     * that sandbox's dictation host. Null means production, which is also
     * where a pasted key goes.
     */
    fun dictationOrigin(context: Context): String? =
        if (load(context) != null) config?.dictationOrigin else null

    /**
     * A new attempt's consent page URL, or null when sign-in isn't configured.
     * The attempt's verifier and state are kept until the redirect comes back,
     * since the browser trip can outlive this process.
     */
    fun beginSignIn(context: Context): Uri? {
        val config = config ?: return null
        val attempt = OAuthAuthorization.create()
        SecureStore.write(
            context,
            PENDING,
            JSONObject().put("verifier", attempt.codeVerifier).put("state", attempt.state).toString(),
        )
        return attempt.url(config)
    }

    /**
     * Finishes a sign-in from the consent page's redirect: code → tokens → key,
     * then stores both. Nothing is stored unless every step succeeds, so a
     * failed attempt leaves a pasted key (or nothing) as it was.
     */
    suspend fun completeSignIn(context: Context, callback: Uri): Outcome {
        val client = client ?: return Outcome.Failed(Messages.UNAVAILABLE)
        val attempt = SecureStore.read(context, PENDING)?.let {
            try {
                val json = JSONObject(it)
                OAuthAuthorization(json.getString("verifier"), json.getString("state"))
            } catch (e: JSONException) {
                null
            }
        } ?: return Outcome.Failed(Messages.CONSENT)
        SecureStore.write(context, PENDING, null)

        val code = try {
            attempt.code(callback)
        } catch (e: OAuthAuthorization.CallbackError.Denied) {
            return Outcome.Cancelled
        } catch (e: OAuthAuthorization.CallbackError) {
            // The callback's error, never its code.
            Log.e(TAG, "sign-in callback refused: ${e.message}")
            return Outcome.Failed(Messages.CONSENT)
        }
        return try {
            val tokens = client.tokens(attempt, code)
            val refreshToken = tokens.refreshToken ?: run {
                Log.e(TAG, "token response carried no refresh token (offline_access not granted?)")
                return Outcome.Failed(Messages.SERVER)
            }
            val key = client.apiKey(tokens.accessToken)
            val session = Session(refreshToken, tokens.email, key.expiresAt, key.rotatesAt, Instant.now())
            generation++
            save(context, session)
            ApiKeyStore.save(context, key.apiKey)
            _status.value = Status.SignedIn(session.email)
            Outcome.SignedIn
        } catch (e: OAuthClient.Failure) {
            Outcome.Failed(Messages.of(e))
        }
    }

    /** Renews when the key is due (or missing). Safe to call often: it's a no-op otherwise. */
    suspend fun renewIfDue(context: Context) = renew(context, force = false)

    /**
     * Dictation refused the stored key (expired early, deleted by an admin, a
     * revoked connection). Renews at once rather than when due, at most once per
     * [rejectedKeyRenewalSpacing]; nothing to do for a pasted key.
     */
    suspend fun keyWasRejected(context: Context) {
        val now = Instant.now()
        lastForcedRenewal?.let { if (Duration.between(it, now) < rejectedKeyRenewalSpacing) return }
        if (load(context) == null) return
        lastForcedRenewal = now
        renew(context, force = true)
    }

    /**
     * Ends the connection server-side, then forgets it here. Returns the message
     * to show, with everything left in place, when the server couldn't confirm:
     * the connection is still live and its key still works. A refresh token the
     * server already refuses means it's already over, which counts as signed
     * out. Null on success.
     */
    suspend fun signOut(context: Context): String? {
        // Waits out a renewal in flight, which may have rotated the refresh
        // token; refreshing with the old one would read as "already over".
        renewal.withLock { return signOutLocked(context) }
    }

    private suspend fun signOutLocked(context: Context): String? {
        val session = load(context) ?: run {
            forget(context)
            return null
        }
        // A build without sign-in configured can't reach the server, but a
        // session it inherited must still be removable.
        val client = client ?: run {
            forget(context)
            return null
        }
        try {
            val tokens = client.refresh(session.refreshToken)
            client.revoke(tokens.accessToken)
        } catch (e: OAuthClient.Failure.Rejected) {
            // Nothing left server-side to end.
        } catch (e: OAuthClient.Failure) {
            return Messages.SIGN_OUT_UNCONFIRMED
        }
        forget(context)
        return null
    }

    private suspend fun renew(context: Context, force: Boolean) {
        renewal.withLock { renewLocked(context, force) }
    }

    private suspend fun renewLocked(context: Context, force: Boolean) {
        val client = client ?: return
        var session = load(context) ?: return
        val hasKey = ApiKeyStore.load(context) != null
        if (!force && hasKey && Instant.now() < session.renewalDue) return
        val started = generation
        try {
            val tokens = client.refresh(session.refreshToken)
            if (generation != started) return
            // Keep a rotated refresh token before anything else can fail: the
            // old one is already dead.
            session = session.copy(
                refreshToken = tokens.refreshToken ?: session.refreshToken,
                email = tokens.email ?: session.email,
            )
            save(context, session)
            val key = client.apiKey(tokens.accessToken)
            if (generation != started) return
            val renewedAt = Instant.now()
            session = session.copy(keyExpiresAt = key.expiresAt, keyRotatesAt = key.rotatesAt, renewedAt = renewedAt)
                .deferRenewalIfStillDue(renewedAt)
            if (ApiKeyStore.load(context) != key.apiKey) ApiKeyStore.save(context, key.apiKey)
            save(context, session)
            _status.value = Status.SignedIn(session.email)
        } catch (e: OAuthClient.Failure.Unreachable) {
            // Offline or the server failed: change nothing, the next trigger tries again.
        } catch (e: OAuthClient.Failure) {
            // Refused: the connection is over (revoked from the dashboard, the
            // member removed, the refresh token lapsed).
            if (generation == started) forget(context)
        }
    }

    /** Drops the session and its key from this phone without telling the server. */
    private fun forget(context: Context) {
        generation++
        SecureStore.write(context, SESSION, null)
        ApiKeyStore.clear(context)
        _status.value = Status.SignedOut
    }

    private fun load(context: Context): Session? =
        SecureStore.read(context, SESSION)?.let(Session::fromJson)

    private fun save(context: Context, session: Session) =
        SecureStore.write(context, SESSION, session.toJson())

    /** The stored sign-in; `SignInSession` on the Mac. */
    private data class Session(
        val refreshToken: String,
        val email: String?,
        val keyExpiresAt: Instant?,
        val keyRotatesAt: Instant?,
        val renewedAt: Instant,
    ) {
        /** The server's rotation time, else two days before expiry, else a day after the last renewal. */
        val renewalDue: Instant
            get() = keyRotatesAt
                ?: keyExpiresAt?.minus(expiryMargin)
                ?: renewedAt.plus(unknownExpiry)

        /**
         * A key that is still due right after renewing (expiring inside the
         * margin, or rotation already past) would renew on every trigger; push
         * the next renewal to the expiry, or a day out.
         */
        fun deferRenewalIfStillDue(now: Instant): Session {
            if (renewalDue > now) return this
            val next = keyExpiresAt?.takeIf { it > now } ?: now.plus(unknownExpiry)
            return copy(keyRotatesAt = next)
        }

        fun toJson(): String = JSONObject()
            .put("refreshToken", refreshToken)
            .put("email", email)
            .put("keyExpiresAt", keyExpiresAt?.toString())
            .put("keyRotatesAt", keyRotatesAt?.toString())
            .put("renewedAt", renewedAt.toString())
            .toString()

        companion object {
            fun fromJson(json: String): Session? = try {
                val o = JSONObject(json)
                fun instant(key: String) = if (o.isNull(key)) null else Instant.parse(o.getString(key))
                Session(
                    refreshToken = o.getString("refreshToken"),
                    email = if (o.isNull("email")) null else o.getString("email"),
                    keyExpiresAt = instant("keyExpiresAt"),
                    keyRotatesAt = instant("keyRotatesAt"),
                    renewedAt = instant("renewedAt") ?: Instant.EPOCH,
                )
            } catch (e: Exception) {
                null
            }
        }
    }

    /** The Mac's wording (`SignInFailure.message`), with "phone" for "Mac". */
    private object Messages {
        const val UNAVAILABLE = "Signing in isn't available in this version of Blurt. Use an API key instead."
        const val CONSENT = "AssemblyAI didn't complete the sign-in. Try again."
        const val SERVER = "Couldn't reach AssemblyAI. Check your connection and try again."
        const val SIGN_OUT_UNCONFIRMED =
            "AssemblyAI couldn't confirm the sign-out, so Blurt is still connected. Check your connection and try again."

        fun of(failure: OAuthClient.Failure): String = when (failure) {
            is OAuthClient.Failure.Forbidden -> failure.reason?.let { "AssemblyAI didn't allow it: $it" }
                ?: "AssemblyAI didn't allow Blurt to use your account. Ask an admin of your organization."
            is OAuthClient.Failure.Rejected -> CONSENT
            is OAuthClient.Failure.Unreachable -> SERVER
        }
    }
}

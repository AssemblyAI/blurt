package com.assemblyai.blurt.android

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.ReceiveChannel
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.util.UUID
import kotlin.coroutines.coroutineContext

/**
 * One dictation = one streamed POST to AssemblyAI's dictation route, the same
 * request the Mac and iPhone apps make (`Sources/BlurtEngine/STT/AssemblyAITranscriber.swift`
 * is the reference, and its comments say why each field is shaped the way it is).
 *
 * The body is multipart, and the order is the route's requirement: the whole
 * `config` part first (the service opens its upstream STT call the moment it
 * lands), then the `audio` part's headers, then each PCM frame as the mic
 * produces it, then the closing boundary once recording stops. So the upload
 * is already done by the time the user taps the bubble the second time.
 */
class DictationClient(private val apiKey: String, private val llmInstruction: String) {

    class DictationException(message: String) : IOException(message)

    /**
     * Streams [frames] (16 kHz mono S16LE) and returns the text to insert: the
     * cleaned-up rewrite when the service produced one, otherwise the verbatim
     * transcript. [sttPrompt] is the text before the cursor, which steers
     * transcription to continue it.
     */
    suspend fun transcribe(frames: ReceiveChannel<ByteArray>, sttPrompt: String): String =
        withContext(Dispatchers.IO) {
            val boundary = "blurt-${UUID.randomUUID()}"
            val connection = (URL(ENDPOINT).openConnection() as HttpURLConnection).apply {
                requestMethod = "POST"
                doOutput = true
                // Chunked, so the request opens now and each frame goes out as it
                // is written rather than after the whole recording is buffered.
                setChunkedStreamingMode(0)
                connectTimeout = CONNECT_TIMEOUT_MS
                readTimeout = READ_TIMEOUT_MS
                // The raw key, no "Bearer" prefix: AssemblyAI's convention.
                setRequestProperty("Authorization", apiKey)
                setRequestProperty("Content-Type", "multipart/form-data; boundary=$boundary")
                setRequestProperty("User-Agent", "Blurt-Android/${BuildConfig.VERSION_NAME}")
            }
            // A cancelled dictation (long-press) is blocked in a socket write or
            // read, which coroutine cancellation can't interrupt; dropping the
            // connection can.
            coroutineContext[Job]?.invokeOnCompletion { cause ->
                if (cause != null) connection.disconnect()
            }
            try {
                connection.outputStream.use { out ->
                    out.write(configPart(boundary, sttPrompt))
                    out.write(audioPartHeader(boundary))
                    out.flush()
                    for (frame in frames) {
                        out.write(frame)
                        out.flush()
                    }
                    out.write("\r\n--$boundary--\r\n".toByteArray())
                }
                val status = connection.responseCode
                val stream = if (status in 200..299) connection.inputStream else connection.errorStream
                val body = stream?.bufferedReader()?.use { it.readText() }.orEmpty()
                if (status !in 200..299) throw DictationException(errorMessage(status, body))
                transcript(body)
            } finally {
                connection.disconnect()
            }
        }

    private fun configPart(boundary: String, sttPrompt: String): ByteArray {
        val config = JSONObject().apply {
            put("sample_rate", MicRecorder.SAMPLE_RATE)
            put("channels", 1)
            // Empty means no prior text, and the key is then left off rather
            // than sent as "".
            val prompt = sttPrompt.takeLast(STT_PROMPT_CAP)
            if (prompt.isNotBlank()) put("stt_prompt", prompt)
            put("llm_instruction", llmInstruction)
        }
        return (
            "--$boundary\r\n" +
                "Content-Disposition: form-data; name=\"config\"\r\n" +
                "Content-Type: application/json\r\n\r\n" +
                config.toString() + "\r\n"
            ).toByteArray()
    }

    private fun audioPartHeader(boundary: String): ByteArray =
        (
            "--$boundary\r\n" +
                "Content-Disposition: form-data; name=\"audio\"; filename=\"audio.pcm\"\r\n" +
                "Content-Type: audio/pcm\r\n\r\n"
            ).toByteArray()

    /** The rewrite is best-effort: null or blank falls back to the verbatim `text`. */
    private fun transcript(body: String): String {
        val json = try {
            JSONObject(body)
        } catch (e: org.json.JSONException) {
            throw DictationException("AssemblyAI sent a response Blurt couldn't read")
        }
        val rewrite = if (json.isNull("llm_response")) null else json.optString("llm_response")
        return rewrite?.takeIf { it.isNotBlank() } ?: json.optString("text")
    }

    /**
     * The route documents two error shapes, `{error, error_code}` and
     * `{status, title, detail}`, and an invalid key comes back as 404 rather
     * than 401.
     */
    private fun errorMessage(status: Int, body: String): String {
        if (status == 401 || status == 404) return "AssemblyAI didn't accept your API key"
        val detail = try {
            val json = JSONObject(body)
            json.optString("error").ifBlank { json.optString("detail") }
        } catch (e: org.json.JSONException) {
            ""
        }
        return detail.ifBlank { "AssemblyAI returned HTTP $status" }
    }

    private companion object {
        const val ENDPOINT = "https://dictation.assemblyai.com/v1/transcribe/live"
        const val CONNECT_TIMEOUT_MS = 15_000
        // An idle timeout, as on the Mac: it has to outlast the rewrite after
        // the last frame, not the whole recording.
        const val READ_TIMEOUT_MS = 90_000
        // `stt_prompt` is capped at 4096 scalars; the most recent text is the
        // part that matters, so the start is what gets cut.
        const val STT_PROMPT_CAP = 4000
    }
}

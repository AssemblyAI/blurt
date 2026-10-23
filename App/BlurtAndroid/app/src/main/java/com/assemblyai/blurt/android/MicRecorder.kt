package com.assemblyai.blurt.android

import android.annotation.SuppressLint
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.ReceiveChannel
import kotlinx.coroutines.launch
import kotlin.math.sqrt

/**
 * Records 16 kHz mono 16-bit PCM, exactly what the dictation route wants, so
 * the frames go on the wire untouched. Frames are 100 ms each.
 *
 * Callers check RECORD_AUDIO before starting.
 */
class MicRecorder(private val onLevel: (Float) -> Unit) {

    @Volatile private var running = false

    /** Bytes captured so far; a dictation shorter than [MIN_BYTES] is dropped. */
    @Volatile var bytesRecorded = 0L
        private set

    @SuppressLint("MissingPermission")
    fun start(scope: CoroutineScope): ReceiveChannel<ByteArray> {
        val frames = Channel<ByteArray>(Channel.UNLIMITED)
        val minBuffer = AudioRecord.getMinBufferSize(
            SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT,
        )
        // VOICE_RECOGNITION: the source tuned for speech-to-text, with no AGC or
        // noise suppression that a call would add.
        val record = AudioRecord(
            MediaRecorder.AudioSource.VOICE_RECOGNITION,
            SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
            maxOf(minBuffer, FRAME_BYTES * 4),
        )
        running = true
        scope.launch(Dispatchers.IO) {
            try {
                // Another app holding the mic, or the permission revoked since
                // the check: close the channel with the reason instead of crashing.
                check(record.state == AudioRecord.STATE_INITIALIZED) { "The microphone isn't available" }
                record.startRecording()
                val buffer = ByteArray(FRAME_BYTES)
                while (running && bytesRecorded < MAX_BYTES) {
                    val read = record.read(buffer, 0, buffer.size)
                    if (read <= 0) continue
                    bytesRecorded += read
                    frames.send(buffer.copyOf(read))
                    onLevel(level(buffer, read))
                }
                frames.close()
            } catch (e: IllegalStateException) {
                frames.close(e)
            } finally {
                if (record.recordingState == AudioRecord.RECORDSTATE_RECORDING) record.stop()
                record.release()
            }
        }
        return frames
    }

    /** Ends the recording; the frame channel closes once the last read lands. */
    fun stop() {
        running = false
    }

    /** RMS of the frame, scaled so normal speech sits around 0.3–0.8. */
    private fun level(buffer: ByteArray, length: Int): Float {
        var sum = 0.0
        var i = 0
        while (i + 1 < length) {
            val sample = (buffer[i].toInt() and 0xFF) or (buffer[i + 1].toInt() shl 8)
            sum += sample.toDouble() * sample
            i += 2
        }
        val rms = sqrt(sum / (length / 2).coerceAtLeast(1)) / Short.MAX_VALUE
        return (rms * 6).toFloat().coerceIn(0f, 1f)
    }

    companion object {
        const val SAMPLE_RATE = 16_000
        private const val FRAME_BYTES = SAMPLE_RATE * 2 / 10
        // The route's limits (`SyncSTTLimits` on the Mac): 0.1 s to 1200 s.
        const val MIN_BYTES = SAMPLE_RATE * 2 / 10
        private const val MAX_BYTES = SAMPLE_RATE * 2 * 1200L
    }
}

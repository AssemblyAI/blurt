import Foundation

public protocol TranscriberProtocol: Sendable {
  /// Transcribe an utterance that is **still being recorded**, uploading the
  /// audio in chunks as the microphone produces it.
  ///
  /// Called at press, not release: the request opens immediately and `frames`
  /// feeds it raw S16LE mono PCM at `sampleRate` (the bytes the capture
  /// delivers, uploaded as-is). Finishing `frames` is what signals
  /// end-of-audio, so the caller ends the stream when recording stops. There is
  /// no buffered variant — a dictation client records in real time, and an
  /// upload that waits for the last sample puts the whole transfer on the path
  /// the user is sitting through. Measured: on a 1 Mbps uplink a 10 s dictation
  /// waits ~3.1 s after speech for a buffered upload versus ~0.5 s chunked.
  ///
  /// `resolveContext` supplies the per-utterance priming (focused app + text
  /// before the cursor, the user's recent dictations) and is called *after* the
  /// last frame, because the `config` part is written last — so the context is
  /// still decided at release, as it was when the whole request was built then.
  /// Return nil for none.
  ///
  /// The dictation API resolves an utterance to a single final transcript, so
  /// this still returns that transcript in one shot (no incremental deltas) —
  /// chunking is about the upload, not the response.
  func transcribe(
    frames: AsyncStream<Data>, sampleRate: Int,
    resolveContext: @escaping @Sendable () async -> TranscriptionContext?
  ) async throws -> String

  /// Optionally pre-open the transcription connection so the next `transcribe`
  /// doesn't pay connection setup (DNS/TCP/TLS) on the latency-sensitive hot
  /// path. Called at record-start, where the handshake overlaps with the user
  /// speaking. Must not throw or block the caller — a failure just means the
  /// real request pays setup as before. Declared here (not only in the default
  /// extension) so it dispatches dynamically through `any TranscriberProtocol`.
  func warmUp() async
}

extension TranscriberProtocol {
  /// No-op default: a transcriber with nothing to pre-open (e.g. test stubs)
  /// inherits this and `DictationSession` can call `warmUp()` unconditionally.
  public func warmUp() async {}
}

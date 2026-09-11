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
  /// `context` supplies the per-utterance priming (focused app + text before the
  /// cursor, the user's recent dictations) as a plain value, resolved *before*
  /// the request opens. It used to be a one-value channel the caller pushed at
  /// release, because the `config` part was written last and could wait on it;
  /// the streaming route puts `config` first, so there is nothing left to wait
  /// with. The caller now owns that wait — see
  /// `DictationSession.startUpload(frames:)`, which bounds it by
  /// `contextWaitBudget` — and hands the settled value in. Pass nil for none.
  ///
  /// Abandonment travels the same simplification: cancelling the task that
  /// called this is the whole of it, because nothing here parks on a channel
  /// that might never deliver.
  ///
  /// A value rather than a closure the request calls back into, so the whole
  /// thing still runs one way: the caller decides the context, then feeds audio,
  /// and the transcriber holds no reference to whatever assembled either.
  ///
  /// The dictation API resolves an utterance to a single final transcript, so
  /// this still returns that transcript in one shot (no incremental deltas) —
  /// chunking is about the upload, not the response.
  func transcribe(
    frames: AsyncStream<Data>, sampleRate: Int, context: TranscriptionContext?
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

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
  /// cursor, the user's recent dictations) as a one-value channel the caller
  /// pushes at release. The `config` part is written last and waits on it, so
  /// the context is still decided at release, as it was when the whole request
  /// was built there. Send nil for none; finishing the channel without a value
  /// abandons the request.
  ///
  /// Read it with `firstOrAbandoned()`, which is that contract as code — every
  /// conformer and test double inherits the abandonment rule instead of
  /// re-deriving it, which three of them were doing and two got wrong.
  ///
  /// A pushed value rather than a closure the request calls back into, so the
  /// whole thing runs one way: the caller sends audio and then context, and the
  /// transcriber holds no reference to whatever assembled them. Pulling the
  /// context back out of the caller also made it a side effect of the request
  /// reaching its config part, so a request that failed earlier left the caller
  /// believing the utterance had no context at all.
  ///
  /// The dictation API resolves an utterance to a single final transcript, so
  /// this still returns that transcript in one shot (no incremental deltas) —
  /// chunking is about the upload, not the response.
  func transcribe(
    frames: AsyncStream<Data>, sampleRate: Int, context: AsyncStream<TranscriptionContext?>
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

extension AsyncStream where Element == TranscriptionContext? {
  /// The one value the caller sends, or `CancellationError` when the channel
  /// finishes without ever sending.
  ///
  /// The abandonment half of `transcribe(frames:sampleRate:context:)`'s
  /// contract, stated once here rather than in each reader. It was prose plus a
  /// hand-rolled `received` flag in the production conformer, and the test
  /// doubles — which skipped the flag — happily returned a transcript for a
  /// dictation the session had already abandoned, so no double could exercise
  /// the rule the protocol documents.
  ///
  /// Deliberately *not* keyed off `Task.isCancelled`: the party reading this is
  /// typically an unstructured task that does not inherit the cancellation, and
  /// learns of the abandonment from this channel closing and nothing else.
  public func firstOrAbandoned() async throws -> TranscriptionContext? {
    for await value in self { return value }
    throw CancellationError()
  }
}

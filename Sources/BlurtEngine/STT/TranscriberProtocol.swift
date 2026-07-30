import Foundation

public protocol TranscriberProtocol: Sendable {
  /// Transcribe captured audio (raw S16LE mono PCM at `sampleRate` — the bytes
  /// `MicCaptureProtocol.stop()` returns, uploaded as-is) into text.
  /// The dictation API resolves an utterance to a single final transcript, so
  /// this returns that transcript in one shot (no incremental deltas).
  ///
  /// `context` carries per-utterance priming (focused app + text before the
  /// cursor) rendered into the request prompt; pass `nil` for none.
  ///
  /// `cleanup` selects which transcript the caller wants: `true` asks the
  /// dictation API for its server-side LLM cleanup rewrite (the `llm` block
  /// rides along and the polished text comes back), `false` omits it so the
  /// verbatim transcript is returned as spoken. It maps straight from the
  /// `DictationMode` that started the session (`DictationMode.cleansUp`).
  func transcribe(
    pcm: Data, sampleRate: Int, context: TranscriptionContext?, cleanup: Bool
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

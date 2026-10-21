import Foundation

/// Wraps a transcriber to report a dictation the API refused for its key, so a
/// signed-in account can renew at once (`AssemblyAIAccount.keyWasRejected`)
/// instead of waiting for its scheduled renewal. The error still reaches the
/// caller unchanged: the utterance can't be retried, because its audio was
/// streamed as it was spoken.
///
/// A refused key is a 401, or the 404 the dictation API relays from the
/// transcription service for an invalid key (see `ErrorResponse`).
public struct KeyRejectionReporter: TranscriberProtocol {
  private let base: any TranscriberProtocol
  private let onRejected: @Sendable () -> Void

  public init(_ base: any TranscriberProtocol, onRejected: @escaping @Sendable () -> Void) {
    self.base = base
    self.onRejected = onRejected
  }

  public func transcribe(
    frames: AsyncStream<Data>, sampleRate: Int, context: TranscriptionContext?
  ) async throws -> String {
    do {
      return try await base.transcribe(frames: frames, sampleRate: sampleRate, context: context)
    } catch let error as AssemblyAIError {
      if case .http(let status, _) = error, status == 401 || status == 404 { onRejected() }
      throw error
    }
  }

  public func warmUp() async {
    await base.warmUp()
  }
}

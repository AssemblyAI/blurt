public import Foundation

/// What a recording streams its audio to and reads its turns from: the realtime
/// API's socket (`RealtimeTranscriber`) in the app, an offline double under UI
/// testing. Exactly the calls a recording makes, in the shapes
/// `RealtimeTranscriber` already answers them, so the protocol adds no
/// behaviour of its own. `AnyObject`, because a recording tells a stale
/// session from the current one by identity.
public protocol LiveTranscriptionSession: AnyObject, Sendable {
  /// Opens the session and returns every turn update as it arrives — a turn's
  /// partials, then its final — until the session ends or fails.
  func start() async -> AsyncThrowingStream<RealtimeTurn, any Error>
  /// Queues recorded PCM (16 kHz mono S16LE) for the session.
  func send(_ pcm: Data) async
  /// Sends what's left and waits for the last turn's final, then closes.
  func finish() async
  /// Closes at once, dropping anything not yet sent.
  func cancel() async
}

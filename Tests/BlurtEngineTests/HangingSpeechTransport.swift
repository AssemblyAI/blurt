import Foundation
import Testing

@testable import AssemblyAI
@testable import BlurtEngine

/// A TTS service that takes the request and never answers it, until the
/// request is cancelled: a read that's still waiting on its first audio.
final class HangingSpeechTransport: SpeechTransport, Sendable {
  private let arrived = AsyncGate()

  /// Returns once the request has arrived.
  func waitUntilAsked() async { await arrived.wait() }

  func stream(_: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, any Error>) {
    arrived.open()
    try await Task.sleep(for: .seconds(60))  // wall-clock-ok: a fake that waits until the test releases or cancels it
    throw URLError(.timedOut)
  }
}

import Foundation
import Synchronization
import Testing

@testable import AssemblyAI
@testable import BlurtEngine

/// A TTS service that takes the request and never answers it, until the
/// request is cancelled: a read that's still waiting on its first audio.
final class HangingSpeechTransport: SpeechTransport, Sendable {
  private let state = Mutex(false)

  var asked: Bool { state.withLock { $0 } }

  func stream(_: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, any Error>) {
    state.withLock { $0 = true }
    while true {
      // wall-clock-ok: a fake that waits until the test releases or cancels it
      try await Task.sleep(for: .milliseconds(5))
    }
  }
}

@testable import BlurtiOS

/// An audio session that counts what the window does to it and says what the
/// test tells it to (`sink`).
@MainActor
final class FakeAudioSession: AudioSessionControlling {
  private(set) var activated = 0
  private(set) var deactivated = 0
  private(set) var preferredApplied = 0
  let events: AsyncStream<AudioSessionEvent>
  let sink: AsyncStream<AudioSessionEvent>.Continuation

  init() {
    (events, sink) = AsyncStream<AudioSessionEvent>.makeStream()
  }

  func activate() { activated += 1 }

  func deactivate() { deactivated += 1 }

  func applyPreferredInput() { preferredApplied += 1 }
}

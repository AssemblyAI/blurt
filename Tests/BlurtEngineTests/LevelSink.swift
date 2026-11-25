import Foundation
import Synchronization
import Testing

@testable import AssemblyAI
@testable import BlurtEngine

/// A sink that plays for a moment at a fixed loudness, so the meter has
/// something to hear before the read finishes.
final class LevelSink: PCMSink {
  let currentLevel: Float

  init(level: Float) { currentLevel = level }
  func enqueue(_: Data) {
    // Only the fixed level matters; the audio itself is dropped.
  }
  func drain() async { try? await Task.sleep(for: .milliseconds(120)) }
  func stop() {
    // Nothing is playing, so there is nothing to stop.
  }
}

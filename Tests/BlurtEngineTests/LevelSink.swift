import Foundation
import Synchronization
import Testing

@testable import AssemblyAI
@testable import BlurtEngine

/// A sink that plays at a fixed loudness until `heard` holds, so the meter has
/// something to hear before the read finishes.
final class LevelSink: PCMSink {
  let currentLevel: Float
  private let heard: @Sendable () -> Bool

  init(level: Float, playsUntil heard: @escaping @Sendable () -> Bool) {
    currentLevel = level
    self.heard = heard
  }
  func enqueue(_: Data) {
    // Only the fixed level matters; the audio itself is dropped.
  }
  func drain() async {
    while !heard() { await Task.yield() }
  }
  func stop() {
    // Nothing is playing, so there is nothing to stop.
  }
}

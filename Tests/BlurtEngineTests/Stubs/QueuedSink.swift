import Foundation

@testable import BlurtEngine

/// A sink that plays nothing and reports a fixed amount of audio still queued.
struct QueuedSink: PCMSink {
  let unplayed: Double
  /// Silent, and never paces the speaker: only the unplayed audio matters here.
  var currentLevel: Float { 0 }
  var bufferedSeconds: Double { 0 }
  var unplayedAudioSeconds: Double { unplayed }

  func enqueue(_: Data) {
    // Plays nothing: only the queue's length matters here.
  }

  func drain() {
    // Nothing queued to wait for.
  }

  func stop() {
    // Nothing playing to silence.
  }
}

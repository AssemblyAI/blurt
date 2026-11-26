import Foundation

@testable import BlurtEngine

/// A sink that plays nothing and reports a fixed amount of audio still queued.
struct QueuedSink: PCMSink {
  let unplayed: Double
  var unplayedAudioSeconds: Double { unplayed }

  func enqueue(_ pcm: Data) {
    // Plays nothing: only the queue's length matters here.
  }

  func drain() async {
    // Nothing queued to wait for.
  }

  func stop() {
    // Nothing playing to silence.
  }
}

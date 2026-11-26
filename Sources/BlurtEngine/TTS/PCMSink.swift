import AVFoundation

/// Where `SelectionSpeaker` sends audio. `StreamingPCMPlayer` is the production
/// conformance. The tests substitute a recorder, since a real sink needs an
/// output device.
protocol PCMSink: Sendable {
  /// The loudness of what's playing now, 0...1, for the pill's meter.
  var currentLevel: Float { get }
  /// Seconds of audio queued ahead of what's playing, in listening time.
  var bufferedSeconds: Double { get }

  func enqueue(_ pcm: Data)
  /// Returns once everything enqueued has played, or `stop()` was called.
  func drain() async
  /// Silences at once. Idempotent.
  func stop()
}

import CoreAudio

/// Classification of a CoreAudio device's transport type
/// (`kAudioDevicePropertyTransportType`).
///
/// Split from `AudioRoute`, which reads the raw value off the hardware and is
/// excluded from the coverage gate for that reason. The *decision* — which
/// transports behave like a buffered wireless link — is pure, and two separate
/// behaviors hang off it, so it lives somewhere `swift test` can pin it:
///
/// - `MicLiveness.timeout(forTransportType:)`, the wait cap for the mic
///   bring-up gate.
/// - `MicCapture`'s tail linger, which keeps capturing past key-up so the last
///   word doesn't get truncated by the link's buffering.
enum AudioTransport {
  /// Whether the transport is a Bluetooth one. Both types count: AirPods and
  /// other wireless headsets report the classic `bluetooth` transport, LE Audio
  /// devices report `bluetoothLE`, and the link characteristic both callers care
  /// about — a slow bring-up and a buffered tail — is the same either way.
  ///
  /// A nil transport (the read failed, or there is no device) answers `false`.
  /// That is the conservative direction for both callers: the short wait cap,
  /// and no linger. Padding every wired capture with a delay would be a worse
  /// regression than losing the tail on a device we couldn't classify.
  static func isBluetooth(_ transportType: UInt32?) -> Bool {
    guard let transportType else { return false }
    return transportType == kAudioDeviceTransportTypeBluetooth
      || transportType == kAudioDeviceTransportTypeBluetoothLE
  }

  /// How much longer capture runs past the key-up that ends it, for a device of
  /// this transport. `.zero` for everything but Bluetooth, so the wired path
  /// skips the wait entirely rather than testing a flag at the call site.
  ///
  /// A Bluetooth link buffers: audio the user has already spoken is still in
  /// flight when `stop()` is called, and `recorder.stop()` drops it — which is
  /// why the last word of a dictation goes missing on AirPods. The value is
  /// deliberately shorter than a typical link's worst case: it buys back the
  /// common tail without making every dictation feel sluggish.
  ///
  /// Lives here beside `MicLiveness.timeout(forTransportType:)` — the other
  /// transport-conditional policy — rather than inside `MicCapture`, so both are
  /// reachable by `swift test`. `MicCapture` needs real hardware and is excluded
  /// from the coverage gate.
  static func tailLinger(forTransportType transportType: UInt32?) -> Duration {
    isBluetooth(transportType) ? bluetoothTailLinger : .zero
  }

  /// See `tailLinger(forTransportType:)`. Exposed so a test can name it rather
  /// than restate the number.
  static let bluetoothTailLinger = Duration.milliseconds(220)
}

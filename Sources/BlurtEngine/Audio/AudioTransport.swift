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
}

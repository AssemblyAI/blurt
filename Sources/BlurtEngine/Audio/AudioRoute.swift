import CoreAudio

/// Read-only queries against the system's current audio routing — the transport
/// facts the capture path needs and the default-output identity the cue players
/// watch.
///
/// **What transport a device is on** is the load-bearing one: a Bluetooth link
/// is both slow to bring up (the wait `MicLiveness` caps) and buffered at the
/// tail (the linger `MicCapture.stop()` grants rather than truncating).
///
/// This stays on CoreAudio deliberately, now that the rest of the input plumbing
/// has moved to `AVCaptureDevice` (see `AudioInputDevices`). `AVCaptureDevice`
/// does expose a `transportType`, and its values are the same four-character
/// codes — `bltn`, `usb `, `virt` and friends were confirmed against real
/// devices — so the read is a plausible one-line replacement. It has *not* been
/// confirmed on a Bluetooth device, and that is the only case any of this
/// matters for: a transport that failed to read as Bluetooth silently costs the
/// 2.5 s liveness cap and the 220 ms tail linger, which is the missing-last-word
/// bug both were added to fix. So the read that has shipped stays until someone
/// verifies the other one with AirPods connected.
///
/// Raw reads only — no policy. What a transport type *means* lives in
/// `AudioTransport` and `MicLiveness`, which are pure and unit-tested; this file
/// needs real hardware to answer anything, so it is excluded from the coverage
/// gate and must not be where a decision hides.
///
/// Internal, not public: the app never asks these directly (it observes route
/// *changes* through `AudioRouteMonitor`), and `.periphery.yml` runs with
/// `retain_public: false`, so a `public` symbol only the engine reaches fails
/// the unused-code scan.
enum AudioRoute {
  /// The default input device's transport type, or nil when there is no input
  /// device (all of them unplugged or asleep) or CoreAudio refused a read.
  ///
  /// Nil is the conservative answer at both consumers: `AudioTransport` reads it
  /// as not-Bluetooth, which means the middle liveness cap and no tail linger.
  static func defaultInputTransportType() -> UInt32? {
    guard let deviceID = defaultDeviceID(for: kAudioHardwarePropertyDefaultInputDevice) else {
      return nil
    }
    return transportType(of: deviceID)
  }

  /// The system's current default *output* device — what `AudioRouteMonitor`
  /// hangs its format listener on. Nil when there is none, or the read failed.
  static func defaultOutputDeviceID() -> AudioDeviceID? {
    defaultDeviceID(for: kAudioHardwarePropertyDefaultOutputDevice)
  }

  // MARK: - CoreAudio addressing

  /// The system-wide audio object, which owns the default-device properties.
  static var systemObject: AudioObjectID { AudioObjectID(kAudioObjectSystemObject) }

  /// A global-scope address for `selector`. Returned fresh per call rather than
  /// stored, because every caller needs its own copy to pass `inout` to
  /// CoreAudio. Shared with `AudioRouteMonitor` and `AudioInputDevices`, which
  /// address the same object graph and would otherwise restate this three-field
  /// literal.
  static func globalAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
  }

  // MARK: - CoreAudio reads

  // Spelled out per property rather than shared behind a generic
  // `read<T>(_:from:initial:)`. That reads better but doesn't compile: `&value`
  // on an unconstrained `T` is "forming 'UnsafeMutableRawPointer' to a variable
  // of type 'T'; this is likely incorrect because 'T' may contain an object
  // reference". Making it work means constraining to `BitwiseCopyable` and going
  // through `withUnsafeMutableBytes` — more machinery than two five-line reads
  // are worth, in a file the coverage gate can't check anyway.

  /// The device the system object reports for `selector` (a default-device
  /// property). Nil covers both a failed read and the "no such device" sentinel,
  /// which callers treat identically.
  private static func defaultDeviceID(for selector: AudioObjectPropertySelector) -> AudioDeviceID? {
    var address = globalAddress(selector)
    var deviceID = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &deviceID)
    // 0 is `kAudioObjectUnknown` — "there is no such device" — spelled as the
    // literal so this doesn't depend on how the constant imports.
    guard status == noErr, deviceID != 0 else { return nil }
    return deviceID
  }

  /// The device's transport type, or nil when the read failed —
  /// `AudioTransport` and `MicLiveness` both treat nil as "not Bluetooth", which
  /// is the conservative direction for each. Internal rather than private so
  /// `AudioInputDevices.transportType(forUID:)` answers for a pinned device from
  /// the same read the default input's answer comes from.
  static func transportType(of deviceID: AudioDeviceID) -> UInt32? {
    var address = globalAddress(kAudioDevicePropertyTransportType)
    var transport = UInt32(0)
    var size = UInt32(MemoryLayout<UInt32>.size)
    let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transport)
    guard status == noErr else { return nil }
    return transport
  }
}

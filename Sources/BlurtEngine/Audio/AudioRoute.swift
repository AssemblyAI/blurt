import CoreAudio

/// The CoreAudio reads that are left: which device is the default *output*, and
/// the property addressing `AudioRouteMonitor` shares with it.
///
/// The input side used to live here too — which device is the default input, and
/// what transport it is on — and both have moved to `AVCaptureDevice`
/// (`AudioInputDevices`), which answers them off the same object the recorder
/// opens. That move waited on confirming `AVCaptureDevice.transportType` reports
/// `blue` for AirPods, because a transport that failed to read as Bluetooth
/// silently costs the 2.5 s liveness cap and the 220 ms tail linger — the
/// missing-last-word bug both exist to fix. It does; the parallel HAL read went.
///
/// Output has no such replacement: `AVCaptureDevice` describes *capture*
/// devices, and what `AudioRouteMonitor` watches is the output route the cue
/// players render into.
///
/// Raw reads only — no policy. Needs real hardware to answer anything, so it is
/// excluded from the coverage gate and must not be where a decision hides.
///
/// Internal, not public: the app never asks these directly (it observes route
/// *changes* through `AudioRouteMonitor`), and `.periphery.yml` runs with
/// `retain_public: false`, so a `public` symbol only the engine reaches fails
/// the unused-code scan.
enum AudioRoute {
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
  /// CoreAudio. Shared with `AudioRouteMonitor`, which addresses the same object
  /// graph and would otherwise restate this three-field literal.
  static func globalAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
  }

  // MARK: - CoreAudio reads

  /// The device the system object reports for `selector` (a default-device
  /// property). Nil covers both a failed read and the "no such device" sentinel,
  /// which callers treat identically.
  ///
  /// Spelled out rather than shared behind a generic `read<T>(_:from:initial:)`.
  /// That reads better but doesn't compile: `&value` on an unconstrained `T` is
  /// "forming 'UnsafeMutableRawPointer' to a variable of type 'T'; this is likely
  /// incorrect because 'T' may contain an object reference". Making it work means
  /// constraining to `BitwiseCopyable` and going through `withUnsafeMutableBytes`
  /// — more machinery than one five-line read is worth, in a file the coverage
  /// gate can't check anyway.
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
}

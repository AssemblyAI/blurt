import CoreAudio

/// Read-only queries against the system's current audio routing — the two facts
/// about the mic that `AVFoundation` doesn't expose but the capture path needs:
///
/// 1. **Which device is the default input**, so `MicCapture` can tell whether a
///    recorder it prepared earlier is still bound to the device the user is
///    about to speak into. `AVAudioRecorder` resolves the route at
///    `prepareToRecord()` time and never re-resolves it, so a recorder warmed
///    before the user connected their AirPods would silently record from the
///    built-in mic.
/// 2. **What transport that device is on**, since a Bluetooth link is both slow
///    to bring up (the wait `MicLiveness` caps) and buffered at the tail (the
///    linger `MicCapture.stop()` grants rather than truncating).
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
  /// Identity plus link character of the default input device, read together in
  /// one pass so the capture path makes a single trip through CoreAudio per
  /// session rather than one per question.
  struct InputSnapshot: Equatable, Sendable {
    /// Which device this is.
    ///
    /// The `AudioDeviceID` rather than the device's persistent UID string, even
    /// though IDs are in principle reusable across an unplug/replug while UIDs
    /// are not. The only consumer is "is the warm recorder still bound to the
    /// device about to be recorded from", and the two disagree in exactly one
    /// case: the warmed device was removed and a new one took its ID inside the
    /// 60 s warm window. That case fails *loudly* — the recorder is bound to a
    /// device that no longer exists, so `record()` returns false and the press
    /// surfaces `.audioCaptureFailed`. It cannot produce the failure the check
    /// exists to prevent, which is silently recording the wrong mic. Reading the
    /// UID instead would mean bridging a `CFString`, i.e. pulling Foundation
    /// into a file that otherwise needs only CoreAudio, to buy a distinction
    /// that changes a loud failure into a slightly louder one.
    let deviceID: AudioDeviceID
    /// The device's CoreAudio transport type, or nil when the read failed.
    /// Interpreted by `AudioTransport.isBluetooth` and
    /// `MicLiveness.timeout(forTransportType:)` — kept raw here so the policy
    /// stays in the files `swift test` can reach.
    let transportType: UInt32?
  }

  /// The default input device as an `InputSnapshot`, or nil when there is no
  /// input device (all of them unplugged or asleep) or CoreAudio refused the
  /// read. Nil is the conservative answer everywhere it's consumed: an unknown
  /// input invalidates a warm recorder rather than silently keeping one bound to
  /// a device that may have gone away.
  static func currentInput() -> InputSnapshot? {
    guard let deviceID = defaultDeviceID(for: kAudioHardwarePropertyDefaultInputDevice) else {
      return nil
    }
    return InputSnapshot(deviceID: deviceID, transportType: transportType(of: deviceID))
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
  /// CoreAudio. Shared with `AudioRouteMonitor`, which addresses the same object
  /// graph and would otherwise restate this three-field literal.
  static func globalAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
  }

  // MARK: - CoreAudio reads

  /// One `AudioObjectGetPropertyData` read of a fixed-size value, or nil when
  /// CoreAudio refused. `initial` supplies both the type and the zero value, so
  /// each caller states the property it wants and nothing else.
  private static func read<T>(
    _ selector: AudioObjectPropertySelector, from object: AudioObjectID, initial: T
  ) -> T? {
    var address = globalAddress(selector)
    var value = initial
    var size = UInt32(MemoryLayout<T>.size)
    let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
    guard status == noErr else { return nil }
    return value
  }

  /// The device the system object reports for `selector` (a default-device
  /// property). Nil covers both a failed read and the "no such device" sentinel,
  /// which callers treat identically.
  private static func defaultDeviceID(for selector: AudioObjectPropertySelector) -> AudioDeviceID? {
    // 0 is `kAudioObjectUnknown` — "there is no such device" — spelled as the
    // literal so this doesn't depend on how the constant imports.
    guard let deviceID = read(selector, from: systemObject, initial: AudioDeviceID(0)),
      deviceID != 0
    else { return nil }
    return deviceID
  }

  /// The device's transport type, or nil when the read failed —
  /// `AudioTransport` and `MicLiveness` both treat nil as "not Bluetooth", which
  /// is the conservative direction for each.
  private static func transportType(of deviceID: AudioDeviceID) -> UInt32? {
    read(kAudioDevicePropertyTransportType, from: deviceID, initial: UInt32(0))
  }
}

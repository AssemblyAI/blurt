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
/// 2. **Whether that device is a Bluetooth one**, whose link buffers audio for
///    a couple of hundred milliseconds — the tail `MicCapture.stop()` waits for
///    rather than truncating (see `bluetoothTailLinger`).
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
    /// Whether the device's transport is Bluetooth, i.e. whether its capture
    /// path carries link latency worth lingering for.
    let isBluetooth: Bool
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
    return InputSnapshot(deviceID: deviceID, isBluetooth: isBluetooth(deviceID))
  }

  /// The system's current default *output* device — what `AudioRouteMonitor`
  /// hangs its format listener on. Nil when there is none, or the read failed.
  static func defaultOutputDeviceID() -> AudioDeviceID? {
    defaultDeviceID(for: kAudioHardwarePropertyDefaultOutputDevice)
  }

  // MARK: - CoreAudio reads

  /// The device the system object reports for `selector` (a default-device
  /// property). Nil covers both a failed read and the "no such device" sentinel,
  /// which callers treat identically.
  private static func defaultDeviceID(for selector: AudioObjectPropertySelector) -> AudioDeviceID? {
    var address = AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var deviceID = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let system = AudioObjectID(kAudioObjectSystemObject)
    let status = AudioObjectGetPropertyData(system, &address, 0, nil, &size, &deviceID)
    // 0 is `kAudioObjectUnknown` — "there is no such device" — spelled as the
    // literal so this doesn't depend on how the constant imports.
    guard status == noErr, deviceID != 0 else { return nil }
    return deviceID
  }

  /// Whether the device is reached over Bluetooth. Both transport types count:
  /// AirPods and other wireless headsets report the classic `bluetooth`
  /// transport, and LE Audio devices report `bluetoothLE` — the link-latency
  /// characteristic the callers care about is the same either way.
  ///
  /// A failed read answers `false`: the conservative default is "no linger",
  /// since padding every wired capture with a delay would be a worse regression
  /// than losing the tail on a device we couldn't classify.
  private static func isBluetooth(_ deviceID: AudioDeviceID) -> Bool {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyTransportType,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var transport = UInt32(0)
    var size = UInt32(MemoryLayout<UInt32>.size)
    let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transport)
    guard status == noErr else { return false }
    return transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
  }
}

import CoreAudio
import Foundation

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
    /// The device's persistent UID. Non-optional on purpose: an unreadable UID
    /// means "we can't tell which device this is", which must not compare equal
    /// to another unknown — so `currentInput()` returns nil instead, and callers
    /// treat that as "assume it changed".
    let uid: String
    /// Whether the device's transport is Bluetooth, i.e. whether its capture
    /// path carries link latency worth lingering for.
    let isBluetooth: Bool
  }

  /// The default input device as an `InputSnapshot`, or nil when there is no
  /// input device (all of them unplugged or asleep) or CoreAudio refused either
  /// read. Nil is the conservative answer everywhere it's consumed: an unknown
  /// input invalidates a warm recorder rather than silently keeping one bound to
  /// a device that may have gone away.
  static func currentInput() -> InputSnapshot? {
    guard let deviceID = defaultDeviceID(for: kAudioHardwarePropertyDefaultInputDevice),
      let uid = uid(of: deviceID)
    else { return nil }
    return InputSnapshot(uid: uid, isBluetooth: isBluetooth(deviceID))
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
    let status = AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
    // 0 is `kAudioObjectUnknown` — "there is no such device" — spelled as the
    // literal so this doesn't depend on how the constant imports.
    guard status == noErr, deviceID != 0 else { return nil }
    return deviceID
  }

  /// The device's persistent UID string. `Unmanaged<CFString>` rather than a
  /// bridged `CFString?`: the property returns a +1 reference, so the ownership
  /// transfer has to be spelled out (`takeRetainedValue`) instead of left to an
  /// implicit bridge that would over-release it.
  private static func uid(of deviceID: AudioDeviceID) -> String? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyDeviceUID,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
    guard status == noErr, let value else { return nil }
    return value.takeRetainedValue() as String
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
    return transport == kAudioDeviceTransportTypeBluetooth
      || transport == kAudioDeviceTransportTypeBluetoothLE
  }
}

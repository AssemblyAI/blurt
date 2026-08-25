import CoreAudio
import Foundation

/// One selectable input device: its persistent CoreAudio UID (what
/// `MicDeviceStore` pins) and its user-facing name (what the Settings picker
/// shows).
public struct AudioInputDevice: Identifiable, Sendable {
  public let uid: String
  public let name: String
  public var id: String { uid }
}

/// Read-only enumeration of the machine's audio *input* devices — the list the
/// Settings microphone picker offers — plus the UID→device translation the
/// capture path resolves a pinned selection with.
///
/// A sibling of `AudioRoute`, not part of it, because these reads bridge
/// `CFString`s (device names and UIDs) and therefore need Foundation, which
/// `AudioRoute` deliberately avoids (see `AudioRoute.InputSnapshot.deviceID`).
/// Like `AudioRoute` it is raw reads only — the policy for a UID that no longer
/// resolves is `MicDeviceSelection.effective`, which is pure and unit-tested —
/// and like `AudioRoute` it needs real hardware to answer anything, so it is
/// excluded from the coverage gate and must not be where a decision hides.
public enum AudioInputDevices {
  /// Every device with at least one input stream, sorted by name for a stable
  /// picker order. Empty when there are none, or CoreAudio refused the read.
  public static func all() -> [AudioInputDevice] {
    deviceIDs()
      .compactMap { deviceID -> AudioInputDevice? in
        guard hasInputStreams(deviceID),
          let uid = stringProperty(kAudioDevicePropertyDeviceUID, of: deviceID),
          let name = stringProperty(kAudioObjectPropertyName, of: deviceID)
        else { return nil }
        return AudioInputDevice(uid: uid, name: name)
      }
      .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }

  /// The current default input device's name — what the picker's "Same as
  /// system (…)" option shows — or nil when there is no input device or a read
  /// failed (the picker then says "Same as system" with no parenthetical).
  public static func systemDefaultInputName() -> String? {
    guard let snapshot = AudioRoute.currentInput() else { return nil }
    return stringProperty(kAudioObjectPropertyName, of: snapshot.deviceID)
  }

  /// The pinned device as an `InputSnapshot` — the same shape
  /// `AudioRoute.currentInput()` answers for the default input, so the
  /// transport-keyed policies (`MicLiveness.timeout`, the tail linger) and the
  /// warm-recorder identity check key off the pinned device exactly as they key
  /// off the default one. Nil when no device carries this UID right now, which
  /// is the missing-device signal `MicDeviceSelection.effective` falls back on.
  static func input(forUID uid: String) -> AudioRoute.InputSnapshot? {
    guard let deviceID = deviceID(forUID: uid) else { return nil }
    return AudioRoute.InputSnapshot(
      deviceID: deviceID, transportType: AudioRoute.transportType(of: deviceID))
  }

  // MARK: - CoreAudio reads

  /// Every audio device the system object lists, input or not — the input
  /// filter is `hasInputStreams`.
  private static func deviceIDs() -> [AudioDeviceID] {
    var address = AudioRoute.globalAddress(kAudioHardwarePropertyDevices)
    var size = UInt32(0)
    let stride = MemoryLayout<AudioDeviceID>.size
    guard
      AudioObjectGetPropertyDataSize(AudioRoute.systemObject, &address, 0, nil, &size) == noErr,
      size >= UInt32(stride)
    else { return [] }
    var deviceIDs = [AudioDeviceID](repeating: 0, count: Int(size) / stride)
    let status = AudioObjectGetPropertyData(
      AudioRoute.systemObject, &address, 0, nil, &size, &deviceIDs)
    guard status == noErr else { return [] }
    return deviceIDs
  }

  /// Whether the device has any input streams — asked as the *size* of its
  /// input-scope stream list, so no variable-length buffer needs decoding just
  /// to learn "more than zero".
  private static func hasInputStreams(_ deviceID: AudioDeviceID) -> Bool {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreams,
      mScope: kAudioObjectPropertyScopeInput,
      mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(0)
    let status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size)
    return status == noErr && size > 0
  }

  /// A CFString property (name, UID) bridged to `String`, or nil when the read
  /// failed. The HAL hands these back retained, hence `takeRetainedValue`.
  private static func stringProperty(
    _ selector: AudioObjectPropertySelector, of objectID: AudioObjectID
  ) -> String? {
    var address = AudioRoute.globalAddress(selector)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
    guard status == noErr, let value else { return nil }
    return value.takeRetainedValue() as String
  }

  /// Translate a device UID to the live `AudioDeviceID` carrying it, via the
  /// system object's translation property (the UID rides in as the qualifier).
  /// Nil covers a failed read and the `kAudioObjectUnknown` sentinel — i.e. the
  /// device isn't connected right now.
  private static func deviceID(forUID uid: String) -> AudioDeviceID? {
    var address = AudioRoute.globalAddress(kAudioHardwarePropertyTranslateUIDToDevice)
    var cfUID = uid as CFString
    var deviceID = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = withUnsafeMutablePointer(to: &cfUID) { qualifier in
      AudioObjectGetPropertyData(
        AudioRoute.systemObject, &address, UInt32(MemoryLayout<CFString>.size), qualifier,
        &size, &deviceID)
    }
    guard status == noErr, deviceID != 0 else { return nil }
    return deviceID
  }
}

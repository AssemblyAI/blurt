@preconcurrency import AVFoundation
import CoreAudio
import Foundation

/// One selectable input device: its persistent UID (what `MicDeviceStore` pins)
/// and its user-facing name (what the Settings picker shows).
public struct AudioInputDevice: Identifiable, Sendable {
  public let uid: String
  public let name: String
  public var id: String { uid }
}

/// Read-only enumeration of the machine's audio *input* devices — the list the
/// Settings microphone picker offers — plus the two questions the capture path
/// asks about a pinned UID: is that device connected, and what transport is it
/// on.
///
/// Enumeration, naming and presence come from **`AVCaptureDevice`**, which is
/// the same API the recorder opens the device with: `uniqueID` *is* the CoreAudio
/// device UID string on macOS (confirmed against real devices — `bltn`-style
/// built-ins, USB interfaces, and virtual devices all round-trip), so the picker
/// lists exactly the devices `CaptureSessionRecorder` can pin to, named the way
/// the rest of the system names them. This replaced ~60 lines of HAL plumbing —
/// a device-list read, an input-stream filter, a `CFString` property bridge and
/// a UID→`AudioDeviceID` translation — that existed only to answer what
/// `AVCaptureDevice` answers in a property.
///
/// The **transport** read stays on CoreAudio, on purpose: see `AudioRoute`'s
/// header for why the one unverified-on-Bluetooth inference was not worth
/// making.
///
/// Like `AudioRoute` this is raw reads only — the policy for a UID that no
/// longer resolves is `MicDeviceSelection.effective`, which is pure and
/// unit-tested — and like `AudioRoute` it needs real hardware to answer
/// anything, so it is excluded from the coverage gate and must not be where a
/// decision hides.
public enum AudioInputDevices {
  /// Every microphone the system offers, sorted by name for a stable picker
  /// order. Empty when there are none.
  ///
  /// A discovery session rather than the deprecated `devices(for:)`, and no
  /// input-stream filter: `mediaType: .audio` already means "can capture audio",
  /// which is the filter the retired HAL path had to reconstruct by asking each
  /// device for the size of its input-scope stream list.
  public static func all() -> [AudioInputDevice] {
    AVCaptureDevice.DiscoverySession(
      deviceTypes: [.microphone], mediaType: .audio, position: .unspecified
    )
    .devices
    .map { AudioInputDevice(uid: $0.uniqueID, name: $0.localizedName) }
    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }

  /// The current default input device's name — what the picker's "Same as
  /// system (…)" option shows — or nil when there is no input device (the picker
  /// then says "Same as system" with no parenthetical).
  public static func systemDefaultInputName() -> String? {
    AVCaptureDevice.default(for: .audio)?.localizedName
  }

  /// Whether a device carrying this UID is connected right now — the
  /// missing-device signal `MicDeviceSelection.effective` falls back on.
  ///
  /// Asked of `AVCaptureDevice` rather than the HAL because it is the same
  /// lookup `CaptureSessionRecorder` will make a moment later to attach the
  /// device: "the pin resolves" and "the recorder can open it" are now one fact
  /// instead of two that could disagree.
  static func isConnected(uid: String) -> Bool {
    AVCaptureDevice(uniqueID: uid)?.isConnected ?? false
  }

  /// The transport type of the device carrying this UID, or nil when it isn't
  /// connected or the read failed — read through CoreAudio so the pinned device
  /// is classified by exactly the property the default input is (see
  /// `AudioRoute`).
  static func transportType(forUID uid: String) -> UInt32? {
    guard let deviceID = deviceID(forUID: uid) else { return nil }
    return AudioRoute.transportType(of: deviceID)
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

@preconcurrency import AVFoundation
import Foundation

/// One selectable input device: its persistent UID (what `MicDeviceStore` pins)
/// and its user-facing name (what the Settings picker shows).
public struct AudioInputDevice: Identifiable, Sendable {
  public let uid: String
  public let name: String
  public var id: String { uid }
}

/// Every question the capture path and the Settings picker ask about input
/// devices: what's available, what it's called, whether a pinned UID still names
/// something connected, and what transport it's on.
///
/// All of it comes from **`AVCaptureDevice`**, which is the same API the recorder
/// opens the device with. `uniqueID` *is* the CoreAudio device UID string on
/// macOS, so the picker lists exactly the devices `CaptureSessionRecorder` can
/// pin to, and "the pin resolves" and "the recorder can open it" are one fact
/// rather than two that could disagree.
///
/// `transportType` is the same four-character code CoreAudio's
/// `kAudioDevicePropertyTransportType` reports — confirmed against real hardware
/// for every case the policies care about: `blue` on AirPods, `bltn` on the
/// built-in mic, `usb ` on USB interfaces, `virt` on virtual devices and `grup`
/// on an aggregate. That confirmation is what retired the parallel CoreAudio
/// read this file used to keep (a device-list read, an input-stream filter, a
/// `CFString` property bridge and a UID→`AudioDeviceID` translation, ~60 lines).
/// The Bluetooth case was the one worth being slow about: a transport that
/// failed to read as Bluetooth silently costs the 2.5 s liveness cap and the
/// 220 ms tail linger, which is the missing-last-word bug both exist to fix.
///
/// Raw reads only — the policy for a UID that no longer resolves is
/// `MicDeviceSelection.effective`, and what a transport *means* is
/// `AudioTransport`; both are pure and unit-tested. This file needs real
/// hardware to answer anything, so it is excluded from the coverage gate and
/// must not be where a decision hides.
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
    systemDefaultDevice?.localizedName
  }

  /// The transport type of the device carrying this UID, or nil when no
  /// connected device does.
  ///
  /// That nil does double duty, and deliberately: it is also the
  /// missing-device signal `MicDeviceSelection.effective` falls back on. The two
  /// used to be separate calls — an `isConnected(uid:)` and this — which meant
  /// two lookups of the same device per press for one question, and two chances
  /// to answer it differently. `transportType(of:)` cannot fail for a device
  /// that exists, so "no transport" and "no device" are the same fact.
  static func transportType(forUID uid: String) -> UInt32? {
    transportType(of: device(forUID: uid))
  }

  /// The transport type of the system default input, or nil when there is no
  /// input device at all. Nil is the conservative answer at both consumers:
  /// `AudioTransport` reads it as not-Bluetooth, which means the middle liveness
  /// cap and no tail linger.
  static func systemDefaultTransportType() -> UInt32? {
    transportType(of: systemDefaultDevice)
  }

  /// The device carrying `uid`, or nil when none does. `isConnected` is checked
  /// as well as the lookup succeeding: a device that has just gone away can
  /// still be handed back, and every caller means "usable right now".
  ///
  /// Internal, not private, because `CaptureSessionRecorder` resolves the same
  /// pin a moment later to attach it — one spelling of "resolve a pin to a
  /// device", so the two layers can't apply different presence rules.
  static func device(forUID uid: String) -> AVCaptureDevice? {
    guard let device = AVCaptureDevice(uniqueID: uid), device.isConnected else { return nil }
    return device
  }

  /// The system default input device. One spelling, shared with the recorder's
  /// fallback and the picker's "Same as system (…)" label.
  static var systemDefaultDevice: AVCaptureDevice? {
    AVCaptureDevice.default(for: .audio)
  }

  /// `AVCaptureDevice.transportType` as the `UInt32` four-character code
  /// `AudioTransport` matches against CoreAudio's `kAudioDeviceTransportType*`
  /// constants. Bit-pattern converted rather than numerically: these are packed
  /// ASCII, and the sign of the `Int32` spelling is an accident of the API.
  private static func transportType(of device: AVCaptureDevice?) -> UInt32? {
    device.map { UInt32(bitPattern: $0.transportType) }
  }
}

import Foundation

/// Which input device dictation records from: the system's default input (the
/// unset default, and Blurt's only behavior before microphone selection
/// existed), or one specific device pinned by its persistent CoreAudio UID.
///
/// This is the *pure* half of microphone selection — the decode rule and the
/// missing-device fallback — kept apart from the hardware questions (what
/// devices exist, what a UID currently resolves to), which live in
/// `AudioInputDevices` and are excluded from the coverage gate. These rules are
/// what `swift test` pins.
public enum MicDeviceSelection: Hashable, Sendable {
  /// Follow the system's default input, re-resolved at every capture.
  case systemDefault
  /// Record from the device with this UID (`kAudioDevicePropertyDeviceUID`).
  /// The UID rather than an `AudioDeviceID` because only the UID survives an
  /// unplug/replug and a reboot — and because it is the identity
  /// `AVCaptureDevice(uniqueID:)` takes, so the string stored here is the one
  /// that opens the device at press time, not a translation of it.
  case pinned(uid: String)

  /// Decode the persisted slot: the empty string — which is also what an unset
  /// key reads back as — means "same as system". Shared by `MicDeviceStore` and
  /// the Settings picker (which observes the raw slot via `@AppStorage`), so
  /// the two can't disagree about what an untouched install means; the same
  /// rule as `SoundPackCatalog.fromPersisted` and `TriggerKey.fromPersisted`.
  public static func fromPersisted(_ raw: String) -> MicDeviceSelection {
    raw.isEmpty ? .systemDefault : .pinned(uid: raw)
  }

  /// The pinned device's UID, or nil for the system default — what a recorder
  /// is built around. Here beside the other encode/decode rules rather than
  /// re-derived by callers switching on the case.
  var pinnedUID: String? {
    switch self {
    case .systemDefault: nil
    case .pinned(let uid): uid
    }
  }

  /// The raw value the store writes for this selection — `fromPersisted`'s
  /// inverse, owned here so the encode and decode rules sit side by side.
  var persistedValue: String {
    switch self {
    case .systemDefault: ""
    case .pinned(let uid): uid
    }
  }

  /// The selection a capture should actually bind to, given whether the pinned
  /// device is currently present. A pinned device that has disappeared falls
  /// back to the system default rather than failing the press: unplugging a USB
  /// mic should degrade dictation to the built-in one, not break it. The pin
  /// itself stays stored, so reconnecting the device pins it again with no trip
  /// through Settings.
  func effective(pinnedDevicePresent: Bool) -> MicDeviceSelection {
    guard case .pinned = self, !pinnedDevicePresent else { return self }
    return .systemDefault
  }
}

/// Persists the microphone selection in `UserDefaults` as the pinned device's
/// UID string, empty (or unset) meaning "same as system". Same shape as
/// `TriggerKeyStore`; lives in the engine so its key is a `DefaultsKey` case and
/// the setting joins `PersistedSettings.resetAll`'s sweep by construction.
public struct MicDeviceStore {
  /// UserDefaults key holding the pinned device UID. Public so SwiftUI views
  /// can observe it directly (e.g. `@AppStorage`) and re-render on change.
  public static var defaultsKey: String { DefaultsKey.micDeviceUID.key }
  private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  public var selection: MicDeviceSelection {
    get {
      MicDeviceSelection.fromPersisted(defaults.string(forKey: Self.defaultsKey) ?? "")
    }
    nonmutating set {
      defaults.set(newValue.persistedValue, forKey: Self.defaultsKey)
    }
  }
}

import Foundation

/// Persists the "lower other audio while dictating" switch in `UserDefaults`,
/// plus the crash-recovery slot for a duck in flight. Off by default; the
/// Settings window's Dictation section flips it. While on, a dictation lowers
/// the system output volume at its start and restores it at its end (see
/// `AudioDucker`, which reads this per dictation, so a change applies to the
/// very next one). Same shape as `DeveloperModeStore`.
public struct AudioDuckStore {
  /// UserDefaults key holding the switch. Public so SwiftUI views can observe
  /// it directly (e.g. `@AppStorage`) and re-render on change.
  public static var defaultsKey: String { DefaultsKey.duckAudio.key }
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  /// `bool(forKey:)` returns false for a missing key, so unset means off.
  ///
  /// Read-only for the same reason as `DeveloperModeStore.isEnabled`: the
  /// Settings toggle writes the slot directly through `@AppStorage`, so a
  /// setter here would have no production caller. Seed the slot to change the
  /// switch.
  var isEnabled: Bool {
    defaults.bool(forKey: Self.defaultsKey)
  }

  // MARK: - Crash-recovery slot

  /// Not `DefaultsKey` cases, deliberately: these record what a duck in flight
  /// owes (the volume to put back), not a setting the user chose — the same
  /// distinction as `SigningIdentityMigration.lastSigningIdentityDefaultsKey`
  /// (see `DefaultsKey`'s doc), so they stay out of the reset sweep and carry
  /// no host prefix. Clearing them on reset would be wrong anyway: a reset
  /// while ducked still owes the user their volume back at the next launch.
  private static let savedVolumeKey = "audioDuck.savedOutputVolume"
  private static let duckedVolumeKey = "audioDuck.duckedOutputVolume"
  private static let deviceUIDKey = "audioDuck.outputDeviceUID"

  /// The restore a duck in flight owes, or nil when none is. Persisted rather
  /// than held in memory so a crash mid-dictation doesn't strand the user at
  /// the ducked volume: `AudioDucker` re-reads this on the next launch's first
  /// terminal render and restores. Written as `Double` because that is what
  /// `UserDefaults` stores numbers as; probed with `object(forKey:)` so a
  /// missing slot reads as nil rather than as a volume of 0.
  var pendingRestore: AudioDucker.PendingRestore? {
    get {
      guard let saved = defaults.object(forKey: Self.savedVolumeKey) as? Double,
        let ducked = defaults.object(forKey: Self.duckedVolumeKey) as? Double
      else { return nil }
      return AudioDucker.PendingRestore(
        saved: Float(saved), ducked: Float(ducked),
        // Absent when the UID read failed at duck time; the restore then falls
        // back to the volume comparison alone.
        deviceUID: defaults.string(forKey: Self.deviceUIDKey))
    }
    nonmutating set {
      guard let newValue else {
        defaults.removeObject(forKey: Self.savedVolumeKey)
        defaults.removeObject(forKey: Self.duckedVolumeKey)
        defaults.removeObject(forKey: Self.deviceUIDKey)
        return
      }
      defaults.set(Double(newValue.saved), forKey: Self.savedVolumeKey)
      defaults.set(Double(newValue.ducked), forKey: Self.duckedVolumeKey)
      if let device = newValue.deviceUID {
        defaults.set(device, forKey: Self.deviceUIDKey)
      } else {
        defaults.removeObject(forKey: Self.deviceUIDKey)
      }
    }
  }
}

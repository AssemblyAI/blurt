import Foundation

// MARK: - Shared defaults

/// Typed access to the App Group's defaults, usable from any thread — the
/// keyboard writes from the main actor, the app's capture path reads from
/// wherever the engine calls it.
package nonisolated enum SharedStore {
  /// The App Group's defaults — what both processes read and write. Falls
  /// back to the process's own only where the group is out of reach (a
  /// keyboard without Full Access), so nothing crashes; nothing is shared then.
  /// Tests point this at a throwaway suite (`override`) so they never touch
  /// the real one.
  package static var defaults: UserDefaults { override ?? shared }
  nonisolated(unsafe) static var override: UserDefaults?
  // `UserDefaults` is thread-safe by contract; the type just isn't marked Sendable.
  nonisolated(unsafe) private static let shared = UserDefaults(suiteName: BlurtShared.appGroup) ?? .standard
  /// `windowMinutes` until the user picks one — also Settings' `@AppStorage`
  /// default, so the picker and the window agree before anything is stored.
  package static let defaultWindowMinutes = 15

  /// Hands-free: a dictation starts the moment the keyboard appears in a text field. Off by default: sessions
  /// come on whenever Blurt opens, so it would record whenever a keyboard came up after, unasked (DESIGN.md).
  package static var autoDictate: Bool {
    get { defaults.bool(forKey: BlurtShared.Key.autoDictate) }
    set { defaults.set(newValue, forKey: BlurtShared.Key.autoDictate) }
  }

  /// How long a listening window stays open with nobody dictating, in minutes.
  /// 0 means until the user closes it.
  package static var windowMinutes: Int {
    get {
      guard defaults.object(forKey: BlurtShared.Key.windowMinutes) != nil else {
        return defaultWindowMinutes
      }
      return defaults.integer(forKey: BlurtShared.Key.windowMinutes)
    }
    set { defaults.set(newValue, forKey: BlurtShared.Key.windowMinutes) }
  }

  package static var listeningUntil: Date? {
    get { defaults.object(forKey: BlurtShared.Key.listeningUntil) as? Date }
    set { defaults.set(newValue, forKey: BlurtShared.Key.listeningUntil) }
  }

  /// Whether AirPods (any Bluetooth headset) may be the microphone while a
  /// session is on. Off by default: the session then prefers the phone's own
  /// mic and allows only A2DP, so music on AirPods stays stereo for the whole
  /// window; on, the session allows HFP and takes their mic. Read when the
  /// session is set up, so a change applies to the next session.
  package static var airPodsMic: Bool {
    get { defaults.bool(forKey: BlurtShared.Key.airPodsMic) }
    set { defaults.set(newValue, forKey: BlurtShared.Key.airPodsMic) }
  }

  package static func write<Value: Encodable>(_ value: Value, forKey key: String) {
    guard let data = try? JSONEncoder().encode(value) else {
      return
    }
    defaults.set(data, forKey: key)
  }

  package static func read<Value: Decodable>(_ type: Value.Type, forKey key: String) -> Value? {
    guard let data = defaults.data(forKey: key) else {
      return nil
    }
    return try? JSONDecoder().decode(type, from: data)
  }

  package static func remove(forKey key: String) {
    defaults.removeObject(forKey: key)
  }
}

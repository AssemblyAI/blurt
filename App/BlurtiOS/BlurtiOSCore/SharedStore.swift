import Foundation

// MARK: - Shared defaults

/// Typed access to the App Group's defaults, usable from any thread — the
/// keyboard writes from the main actor, the app's capture path reads from
/// wherever the engine calls it.
///
/// A value, handed to whatever reads or writes the group: `live` at the app's
/// and the keyboard's entry points, a throwaway suite of its own (`scratch`)
/// in each test. Nothing reaches the group through a global, so a test that
/// forgets an argument fails to compile rather than writing to the real suite
/// the installed app and keyboard share — and two tests running side by side
/// never see each other's records.
package nonisolated struct SharedStore: Sendable {
  /// `windowMinutes` until the user picks one — also Settings' `@AppStorage`
  /// default, so the picker and the window agree before anything is stored.
  package static let defaultWindowMinutes = 15

  /// The App Group's defaults — what both processes read and write. Falls
  /// back to the process's own only where the group is out of reach (a
  /// keyboard without Full Access), so nothing crashes; nothing is shared then.
  package static let live = Self(defaults: UserDefaults(suiteName: BlurtShared.appGroup) ?? .standard)

  /// The suite every member reads and writes; Settings' `@AppStorage` binds to
  /// it. `UserDefaults` is thread-safe by contract; the type just isn't marked
  /// Sendable.
  nonisolated(unsafe) package let defaults: UserDefaults
  /// Put in front of every Darwin signal this store posts or observes
  /// (`post`, `observe`): empty for `live`, so the two processes hear each
  /// other; a scratch store's own otherwise, because Darwin notifications are
  /// system-wide, and two tests posting one name would hear each other.
  package let signalPrefix: String

  /// Hands-free: a dictation starts the moment the keyboard appears in a text field. Off by default: sessions
  /// come on whenever Blurt opens, so it would record whenever a keyboard came up after, unasked (DESIGN.md).
  package var autoDictate: Bool {
    get { defaults.bool(forKey: BlurtShared.Key.autoDictate) }
    nonmutating set { defaults.set(newValue, forKey: BlurtShared.Key.autoDictate) }
  }

  /// How long a listening window stays open with nobody dictating, in minutes.
  /// 0 means until the user closes it.
  package var windowMinutes: Int {
    get {
      guard defaults.object(forKey: BlurtShared.Key.windowMinutes) != nil else {
        return Self.defaultWindowMinutes
      }
      return defaults.integer(forKey: BlurtShared.Key.windowMinutes)
    }
    nonmutating set { defaults.set(newValue, forKey: BlurtShared.Key.windowMinutes) }
  }

  package var listeningUntil: Date? {
    get { defaults.object(forKey: BlurtShared.Key.listeningUntil) as? Date }
    nonmutating set { defaults.set(newValue, forKey: BlurtShared.Key.listeningUntil) }
  }

  /// Whether AirPods (any Bluetooth headset) may be the microphone while a
  /// session is on. Off by default: the session then prefers the phone's own
  /// mic and allows only A2DP, so music on AirPods stays stereo for the whole
  /// window; on, the session allows HFP and takes their mic. Read when the
  /// session is set up, so a change applies to the next session.
  package var airPodsMic: Bool {
    get { defaults.bool(forKey: BlurtShared.Key.airPodsMic) }
    nonmutating set { defaults.set(newValue, forKey: BlurtShared.Key.airPodsMic) }
  }

  /// A store over `defaults`, posting and observing its signals under `signalPrefix`.
  package init(defaults: UserDefaults, signalPrefix: String = "") {
    self.defaults = defaults
    self.signalPrefix = signalPrefix
  }

  /// A store over a throwaway suite of its own, with signals of its own — the
  /// engine's `freshDefaults()` for the App Group. What every unit test builds
  /// its types over, and what the app hands the coordinator when it is only
  /// hosting the tests, so nothing they write reaches the real group.
  package static func scratch(_ label: String = "scratch") -> Self {
    let name = "\(label)-\(UUID().uuidString)"
    guard let suite = UserDefaults(suiteName: name) else {
      // `init(suiteName:)` refuses only the app's bundle id and the global
      // domain; a UUID-suffixed name can be neither.
      preconditionFailure("could not create UserDefaults suite \(name)")
    }
    suite.removePersistentDomain(forName: name)
    return Self(defaults: suite, signalPrefix: "\(name).")
  }

  package func write<Value: Encodable>(_ value: Value, forKey key: String) {
    guard let data = try? JSONEncoder().encode(value) else {
      return
    }
    defaults.set(data, forKey: key)
  }

  package func read<Value: Decodable>(_ type: Value.Type, forKey key: String) -> Value? {
    guard let data = defaults.data(forKey: key) else {
      return nil
    }
    return try? JSONDecoder().decode(type, from: data)
  }

  package func remove(forKey key: String) {
    defaults.removeObject(forKey: key)
  }
}

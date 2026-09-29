import Foundation

/// Persists the last app version whose launch the What's New sheet has dealt
/// with, so the next launch can tell an update from an ordinary relaunch (see
/// `Changelog.whatsNewAtLaunch`). Same shape as `LastUpdateCheckStore`; its key
/// is a `DefaultsKey` case, so every "reset to a clean state" sweep clears it too.
public struct LastSeenVersionStore {
  /// Public so the reset sweep can name it.
  public static var defaultsKey: String { DefaultsKey.lastSeenVersion.key }

  private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  /// The version last recorded, or `nil` if none ever was (or what's stored
  /// doesn't parse, which reads the same way).
  public var lastSeen: SemanticVersion? {
    get { defaults.string(forKey: Self.defaultsKey).flatMap(SemanticVersion.init) }
    nonmutating set { defaults.set(newValue?.description, forKey: Self.defaultsKey) }
  }
}

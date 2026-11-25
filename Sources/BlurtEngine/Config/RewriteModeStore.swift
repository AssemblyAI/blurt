public import Foundation

/// Persists the chosen `RewriteMode` as its raw value in `UserDefaults`. Reads
/// as Smart when unset or when the stored value isn't a known mode.
/// The transcriber reads it at each request (`AssemblyAITranscriber`), so a
/// change applies to the very next dictation. Same shape as `TriggerActivationStore`.
public struct RewriteModeStore {
  /// UserDefaults key holding the mode. Public so SwiftUI views can observe it
  /// directly (e.g. `@AppStorage`) and re-render on change.
  public static var defaultsKey: String { DefaultsKey.rewriteMode.key }

  private let defaults: UserDefaults

  /// The rewrite model dictation asks for; unset or unknown reads as the default.
  public var mode: RewriteMode {
    get { RewriteMode.fromPersisted(defaults.string(forKey: Self.defaultsKey) ?? "") }
    nonmutating set { defaults.set(newValue.rawValue, forKey: Self.defaultsKey) }
  }

  /// A store over `defaults`; tests pass an isolated suite.
  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }
}

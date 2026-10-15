import Foundation

/// Which model the dictation API's server-side cleanup rewrite runs on — the
/// request's `rewrite_mode` option. Fast is the model every request has used so
/// far and the unset default; Smart opts in to a larger one that rewrites better
/// and takes longer. The raw value is what `RewriteModeStore` persists, so it
/// follows `DefaultsKey`'s rule: rename a case freely, its raw value never.
public enum RewriteMode: String, CaseIterable, Sendable {
  /// The shipped behavior, and the unset default (`fromPersisted`).
  case fast = "Fast"
  /// The larger rewrite model. It has a longer server-side path, and a rewrite
  /// that misses the route's budget comes back as `llm_error` and degrades to the
  /// verbatim transcript (`AssemblyAITranscriber.transcript(from:)`).
  case smart = "Smart"

  /// Decodes a persisted raw value, falling back to Fast for unset ("") or
  /// unknown values. The single decode-with-default rule shared by
  /// `RewriteModeStore` and the `@AppStorage` view that reads the raw slot.
  public static func fromPersisted(_ raw: String) -> RewriteMode {
    RewriteMode(rawValue: raw) ?? .fast
  }

  /// Menu-picker title.
  public var label: String {
    switch self {
    case .fast: return "Fast"
    case .smart: return "Smart"
    }
  }

  /// The Settings footer sentence under the picker.
  public static let guidance = "Smart uses a larger model for better rewrites; Fast is quicker."

  /// What goes on the wire as `rewrite_mode`, or nil to omit the key. Fast
  /// **omits** it rather than sending `"fast"`, so the default request stays
  /// byte-identical to the one that shipped before this setting existed.
  var wireValue: String? {
    switch self {
    case .fast: return nil
    case .smart: return "smart"
    }
  }
}

/// Persists the chosen `RewriteMode` as its raw value in `UserDefaults`. Reads
/// as Fast when unset or when the stored value isn't a known mode.
/// `AssemblyAITranscriber` reads it at each request, so a change applies to the
/// very next dictation. Same shape as `TriggerActivationStore`.
public struct RewriteModeStore {
  /// UserDefaults key holding the mode. Public so SwiftUI views can observe it
  /// directly (e.g. `@AppStorage`) and re-render on change.
  public static var defaultsKey: String { DefaultsKey.rewriteMode.key }
  private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  public var mode: RewriteMode {
    get { RewriteMode.fromPersisted(defaults.string(forKey: Self.defaultsKey) ?? "") }
    nonmutating set { defaults.set(newValue.rawValue, forKey: Self.defaultsKey) }
  }
}

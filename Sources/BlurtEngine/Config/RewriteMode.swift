import AssemblyAI

/// Which model the dictation API's server-side cleanup rewrite runs on — the
/// request's `rewrite_mode` option. Smart, the unset default, asks for the
/// larger model that rewrites better and takes longer; Fast opts back in to the
/// quicker one every request used before Smart became the default. The raw value is what `RewriteModeStore` persists, so it
/// follows `DefaultsKey`'s rule: rename a case freely, its raw value never.
public enum RewriteMode: String, CaseIterable, Sendable {
  /// The quicker rewrite model — the service's own default when `rewrite_mode`
  /// is absent.
  case fast = "Fast"
  /// The larger rewrite model, and the unset default (`fromPersisted`). It has a longer server-side path, and a rewrite
  /// that misses the route's budget comes back as `llm_error` and degrades to the
  /// verbatim transcript (`AssemblyAITranscriber.transcript(from:enhanced:)`).
  case smart = "Smart"

  /// The Settings footer sentence under the picker.
  public static let guidance = "Smart uses a larger model for better rewrites; Fast is quicker."

  /// Menu-picker title.
  public var label: String {
    switch self {
    case .fast:
      return "Fast"

    case .smart:
      return "Smart"
    }
  }

  /// What goes on the wire as `rewrite_mode`, or nil to omit the key. Fast
  /// **omits** it rather than sending `.fast`, so a Fast request stays
  /// byte-identical to the one that shipped before this setting existed.
  var wireValue: DictationRewriteMode? {
    switch self {
    case .fast:
      return nil

    case .smart:
      return .smart
    }
  }

  /// Decodes a persisted raw value, falling back to Smart for unset ("") or
  /// unknown values. The single decode-with-default rule shared by
  /// `RewriteModeStore` and the `@AppStorage` view that reads the raw slot.
  public static func fromPersisted(_ raw: String) -> Self {
    Self(rawValue: raw) ?? .smart
  }
}

import Foundation

/// Storage for the user's custom style instructions — free text (e.g. "add some
/// emojis where appropriate sparingly", "always write in lowercase") appended to
/// the cleanup instruction so the dictation API's server-side rewrite also
/// applies the user's formatting preferences (see
/// `CleanupInstruction.sendable(appending:)`). Optional: unset or blank sends
/// exactly the instruction that ships today. Inert while enhanced transcripts
/// are off, since the `llm` block the instruction rides on is omitted entirely.
/// `AssemblyAITranscriber` reads this at each request, so an edit applies to the
/// very next dictation.
///
/// Read-only for the same reason as `KeyTermsStore`: the Settings field binds
/// `@AppStorage` straight to `defaultsKey` and is the sole writer — a
/// normalizing setter fights the text field — so trimming lives on the read
/// side and a whitespace-only field still reads back as "no instructions".
public struct CustomStyleStore {
  /// `UserDefaults` key for the raw text the user typed. Public so the Settings
  /// field can bind `@AppStorage` to it.
  public static var defaultsKey: String { DefaultsKey.customStyle.key }

  /// The most UTF-8 bytes the Settings field accepts —
  /// `CleanupInstruction.customStyleBudget`, the real headroom the dictation
  /// API's 2048 instruction cap leaves after the base instruction (see
  /// `CleanupInstruction.characterCap` for why the unit is bytes).
  /// Re-exported here (the field's counter and the engine's trim have to agree)
  /// rather than restated, which is how the cap bug shipped once before.
  public static let characterLimit = CleanupInstruction.customStyleBudget

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  /// The instructions to append, trimmed, or `nil` when unset or blank — blank
  /// must mean "send the base instruction untouched", not an empty suffix.
  var instructions: String? {
    defaults.string(forKey: Self.defaultsKey).trimmedNonEmpty()
  }
}

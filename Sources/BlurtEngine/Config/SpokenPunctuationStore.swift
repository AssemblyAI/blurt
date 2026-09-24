import Foundation

/// Persists the "speak all punctuation" switch in `UserDefaults`. Off by
/// default; the Settings window's Transcription section flips it.
///
/// While on, the pipeline pastes only the punctuation the user *said*: every
/// mark the service inserted is stripped and spoken ones ("comma", "question
/// mark", "new paragraph") are put back as symbols — see
/// `SpokenPunctuationFormatter`. The verbatim transcript is formatted rather
/// than the cleanup rewrite, which is told to fix punctuation and so may turn a
/// spoken "comma" into a mark the formatter would then strip; so this mode
/// overrides enhanced transcripts, and with them the active style
/// (`EnhancedTranscriptsStore.pastesRewrite`).
/// Read at every dictation, so a change applies to the next one. Same shape as
/// `DeveloperModeStore`.
public struct SpokenPunctuationStore {
  /// UserDefaults key holding the switch. Public so SwiftUI views can observe
  /// it directly (e.g. `@AppStorage`) and re-render on change.
  public static var defaultsKey: String { DefaultsKey.spokenPunctuation.key }
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  /// `bool(forKey:)` returns false for a missing key, so unset means off.
  ///
  /// Read-only for the reason on `DeveloperModeStore.isEnabled`: the Settings
  /// toggle writes the slot through `@AppStorage`, so a setter here would have
  /// no production caller. Seed the slot to change the switch.
  var isEnabled: Bool {
    defaults.bool(forKey: Self.defaultsKey)
  }
}

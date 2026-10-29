import Foundation

/// The style one dictation is made with, resolved once at press from the
/// trigger key that started it (`TriggerKeyStyleStore`) — else the main
/// window's selection. A value carried by that dictation (the press command
/// names the key, the session resolves it), so a key's style never moves the
/// main window's sticky selection, and a later press can't restyle a dictation
/// already under way.
public struct PressStyle: Sendable, Equatable {
  /// Appended to the cleanup instruction — `TranscriptionContext`'s
  /// `styleInstructions`. Nil under base styling or for a blank style.
  public let instructions: String?
  /// The custom style named on the dictation's Recent row. Nil with enhanced
  /// transcripts off (no rewrite, so no style applied) or under base styling.
  public let name: String?

  public init(instructions: String?, name: String?) {
    self.instructions = instructions
    self.name = name
  }

  /// Base styling, unnamed: no style appended, none on the Recent row.
  public static let none = PressStyle(instructions: nil, name: nil)

  /// `key`'s style, or the main window's selection for nil, a key with no
  /// style, or one whose style is gone (`StyleProfileStore.profile(for:)`).
  init(key: TriggerKey?, defaults: UserDefaults = .standard) {
    let styleID = key.flatMap { TriggerKeyStyleStore(defaults: defaults).styles[$0] }
    let profile = StyleProfileStore(defaults: defaults).profile(for: styleID)
    let isEnhanced = EnhancedTranscriptsStore(defaults: defaults).isEnabled
    self.init(instructions: profile?.appendedInstructions, name: isEnhanced ? profile?.name : nil)
  }
}

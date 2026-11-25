public import Foundation

/// One named set of style instructions — free text (e.g. "add some emojis where
/// appropriate sparingly", "always write in lowercase") that the dictation API's
/// server-side rewrite applies on top of the base cleanup instruction (see
/// `CleanupInstruction.sendable(appending:)`).
///
/// The `id` is what the active-profile pointer and the main window's switcher
/// are keyed on, so it is assigned once at creation and never re-derived from
/// the name: renaming a profile must not silently deactivate it.
public struct StyleProfile: Codable, Identifiable, Hashable, Sendable {
  public let id: UUID
  public var name: String
  public var instructions: String

  /// What this profile appends to the cleanup instruction: its text, or nil
  /// when blank — which must mean "send the base instruction untouched", not
  /// an empty suffix.
  var appendedInstructions: String? { instructions.trimmedNonEmpty() }

  /// A brand-new profile. The id is generated here rather than by the caller so
  /// there is one place that mints them.
  public init(name: String, instructions: String) {
    self.init(id: UUID(), name: name, instructions: instructions)
  }

  /// Full init, used by the decoder and by the migration's fixed-id profile.
  init(id: UUID, name: String, instructions: String) {
    self.id = id
    self.name = name
    self.instructions = instructions
  }
}

extension StyleProfile {
  // periphery:ignore - public for the iOS app (App/BlurtiOS), which the Mac scan doesn't index.
  /// Whether a profile from these fields can be saved: both say something. A
  /// nameless profile would render a blank segment in the main window's
  /// switcher, and one with no instructions would be a style that changes
  /// nothing about the dictation it selects. The one rule behind the Mac's
  /// editor sheet and the iPhone's, as `TextShortcut.canSave` is for shortcuts.
  public static func canSave(name: String, instructions: String) -> Bool {
    name.trimmedNonEmpty() != nil && instructions.trimmedNonEmpty() != nil
  }
}

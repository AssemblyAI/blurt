public import Foundation

// The edits both apps' editors make to the stored text shortcuts — field caps applied as
// the user types, save-or-add by id, and remove by id — once, here, rather than
// once per editor sheet. The store's own `normalized` still runs on every
// write; the caps keep a field from ever holding more than will be stored, so
// text is never lost silently at save.

extension TextShortcutStore {
  // periphery:ignore - public for the iOS app (App/BlurtiOS), which the Mac scan doesn't index.
  /// `trigger` held to `triggerLimit` characters, as the editor's field allows.
  public static func clampedTrigger(_ trigger: String) -> String {
    String(trigger.prefix(triggerLimit))
  }

  // periphery:ignore - public for the iOS app (App/BlurtiOS), which the Mac scan doesn't index.
  /// `expansion` held to `expansionLimit` characters.
  public static func clampedExpansion(_ expansion: String) -> String {
    String(expansion.prefix(expansionLimit))
  }

  /// Saves `shortcut` over the stored one with its id, or adds it at the end —
  /// against the stored list, for the reason on `StyleProfileStore.save(_:)`.
  public func save(_ shortcut: TextShortcut) {
    shortcuts = shortcuts.upserting(shortcut)
  }

  // periphery:ignore - public for the iOS app (App/BlurtiOS), which the Mac scan doesn't index.
  /// Adds `shortcut` ahead of the stored ones, where a list showing the newest
  /// first wants it.
  public func insertFirst(_ shortcut: TextShortcut) {
    shortcuts = [shortcut] + shortcuts
  }

  /// Removes the stored shortcut with `id`, if there is one.
  public func remove(id: TextShortcut.ID) {
    shortcuts = shortcuts.filter { $0.id != id }
  }
}

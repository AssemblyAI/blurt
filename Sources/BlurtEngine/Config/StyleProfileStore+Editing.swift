public import Foundation

// The edits both apps' editors make to the stored style profiles — field caps applied as
// the user types, save-or-add by id, and remove by id — once, here, rather than
// once per editor sheet. The store's own `normalized` still runs on every
// write; the caps keep a field from ever holding more than will be stored, so
// text is never lost silently at save.

extension StyleProfileStore {
  // periphery:ignore - public for the iOS app (App/BlurtiOS), which the Mac scan doesn't index.
  /// `name` held to `nameLimit` characters, as the editor's field allows.
  public static func clampedName(_ name: String) -> String {
    String(name.prefix(nameLimit))
  }

  // periphery:ignore - public for the iOS app (App/BlurtiOS), which the Mac scan doesn't index.
  /// `instructions` held to `characterLimit` UTF-8 bytes, whole graphemes only,
  /// so what is stored is what is sent.
  public static func clampedInstructions(_ instructions: String) -> String {
    instructions.prefix(maxUTF8Bytes: characterLimit)
  }

  /// Saves `profile` over the stored one with its id, or adds it at the end.
  /// Merged against the *stored* list rather than a view's observed copy, so a
  /// change made in another window while an editor was open isn't clobbered.
  public func save(_ profile: StyleProfile) {
    profiles = profiles.upserting(profile)
  }

  /// Removes the stored profile with `id`, if there is one. Deleting the
  /// active one falls back to the first remaining (`active(in:id:)`).
  public func remove(id: StyleProfile.ID) {
    profiles = profiles.filter { $0.id != id }
  }
}

extension Array where Element: Identifiable {
  /// The list with `element` in place of the one sharing its id, or appended
  /// when there is none — an edit made elsewhere since the editor opened
  /// deleted it, or it is new.
  func upserting(_ element: Element) -> Self {
    var list = self
    if let index = list.firstIndex(where: { $0.id == element.id }) {
      list[index] = element
    } else {
      list.append(element)
    }
    return list
  }
}

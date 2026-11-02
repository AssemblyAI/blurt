import Accessibility
import AppKit
import BlurtEngine
import SwiftUI

extension View {
  /// The one delete confirmation for a saved entry, wherever it's deleted
  /// from — the Recent list's row, its menu, the Delete key, the sheet: a
  /// destructive Delete, and a message saying what goes with it.
  /// `willDelete` hears the entry just before it goes — the list moves its
  /// selection on. `closesSheet` is for the transcript sheet's own Delete,
  /// where deleting the open entry closes the sheet the dialog belongs to:
  /// there the delete waits for the dialog to finish closing, or the sheet
  /// is torn down mid-animation and left empty. Everywhere else it's immediate.
  func deleteConfirmation(
    for entry: Binding<SavedTranscript?>, model: TranscriptsModel, closesSheet: Bool = false,
    willDelete: @escaping (SavedTranscript) -> Void = { _ in }
  ) -> some View {
    // A title that doesn't depend on the entry: it would read "Delete “”?"
    // for the moment the dialog animates out after the entry is cleared.
    confirmationDialog(
      "Delete this item?",
      isPresented: Binding(get: { entry.wrappedValue != nil }, set: { if !$0 { entry.wrappedValue = nil } }),
      presenting: entry.wrappedValue
    ) { entry in
      Button("Delete", role: .destructive) {
        willDelete(entry)
        if closesSheet {
          Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            model.delete(entry)
          }
        } else {
          model.delete(entry)
        }
      }
      // Explicit, so Return lands on Cancel and never on the destructive button.
      Button("Cancel", role: .cancel) {}
    } message: { entry in
      Text(
        "\u{201C}\(entry.title)\u{201D} "
          + (entry.ownsAudio
            ? "and its audio will be deleted. This can't be undone." : "will be deleted. This can't be undone."))
    }
  }
}

extension NSPasteboard {
  /// Copies `text` for the history's Copy actions — the list's and the
  /// sheet's — and says so to VoiceOver, since the write has no visible effect.
  static func copyAnnounced(_ text: String) {
    general.clearContents()
    general.setString(text, forType: .string)
    AccessibilityNotification.Announcement("Copied").post()
  }
}

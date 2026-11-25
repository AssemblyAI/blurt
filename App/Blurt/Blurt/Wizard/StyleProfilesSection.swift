import BlurtEngine
import SwiftUI

/// The Styles section of the Settings window: up to
/// `StyleProfileStore.profileLimit` named sets of style instructions, the active
/// one of which is appended to the cleanup instruction on every dictation
/// request (see `CleanupInstruction.sendable(appending:)` / `StyleProfileStore`),
/// so the enhanced-transcript polish also applies the user's formatting
/// preferences. Optional — with none defined the request is exactly what ships
/// today. Disabled while enhanced transcripts are off, since the instruction
/// they extend is not sent at all then.
///
/// Each row is a name and a way in: all editing happens in the sheet below, for
/// the reasons on `APIKeyStepView`'s. Which style is *active* is deliberately
/// not set here — the main window's switcher owns that (see `ReadyView`), so
/// switching is one click instead of a trip through Settings, and a second
/// control here would be two writers on the same slot.
struct StyleProfilesSection: View {
  @AppStorage(EnhancedTranscriptsStore.defaultsKey)
  private var enhancedTranscripts = EnhancedTranscriptsStore.defaultValue

  /// Bound to observe, not to write: the store owns the JSON encoding, so it
  /// decodes this slot and the sheet writes through it, while `@AppStorage` is
  /// what re-renders these rows when a write lands.
  @AppStorage(StyleProfileStore.defaultsKey)
  private var rawProfiles = ""

  /// The profile the sheet is editing, or nil while it's closed. Carries the
  /// value rather than an index, so a list that changes underneath can't leave
  /// the sheet pointed at a different profile.
  @State private var editing: StyleProfile?

  private var profiles: [StyleProfile] { StyleProfileStore().profiles(decoding: rawProfiles) }

  var body: some View {
    Section {
      // Enumerated for the accessibility identifier only — identity is the
      // profile's own stable id, so a rename doesn't rebuild the row.
      ForEach(Array(profiles.enumerated()), id: \.element.id) { index, profile in
        // The instructions' first line as a preview, so styles can be told
        // apart without opening each one.
        SettingRow(
          title: profile.name,
          systemImage: "textformat",
          subtitle: profile.instructions.split(whereSeparator: \.isNewline).first.map(String.init)
        ) {
          Button("Edit…") { editing = profile }
            .accessibilityIdentifier(UITestIdentifiers.styleProfileEdit(index))
        }
      }
      // Ellipsis for the same reason as the API-key row's "Connect…": the
      // action needs more input before it completes.
      SettingRow(
        title: profiles.isEmpty ? "Create your first style" : "New style",
        systemImage: "text.badge.plus",
        subtitle: "For example, casual tone and lowercase text."
      ) {
        Button("Add Style…") { editing = StyleProfile(name: "", instructions: "") }
          .disabled(profiles.count >= StyleProfileStore.limit)
          .accessibilityIdentifier(UITestIdentifiers.styleProfileAdd)
      }
    } header: {
      Text("Custom styles")
    } footer: {
      // The caveat *replaces* the explanation rather than joining it: with
      // enhanced transcripts off the rewrite a style shapes is discarded
      // unread, so pointing at the switch just above is the useful half.
      Text(
        enhancedTranscripts
          ? "Create up to \(StyleProfileStore.limit) styles for tone and formatting. Choose the active style in the main window."
          : StylesInertNotice.settingsText
      )
    }
    .disabled(!enhancedTranscripts)
    .sheet(item: $editing) { profile in
      StyleProfileEditorSheet(profile: profile, isExisting: profiles.contains(profile))
    }
  }
}

import BlurtEngine
import SwiftUI

/// One saved entry as a compact two-line row — Journal's entry card, much
/// denser: its kind's glyph, the title (the LLM's for a recording, else the
/// start of the text) over its details and time of day — the day is the
/// section heading — and a ⋯ menu of its actions, as each Journal entry has.
/// A click on the card opens it; the same actions are its contextual menu.
struct HistoryRow: View {
  /// Wide enough for the widest kind glyph.
  private static let iconWidth: CGFloat = 20

  let entry: SavedTranscript
  let details: String
  let dayTitle: String
  let actions: EntryActions

  var body: some View {
    let title = entry.title
    let time = entry.date.formatted(date: .omitted, time: .shortened)
    HStack(spacing: 8) {
      // Centred on both lines, in a slot of one width, so every title starts
      // at the same x whatever the kind's glyph.
      Image(systemName: LibraryKind(entry).systemImage)
        .foregroundStyle(.secondary)
        .frame(width: Self.iconWidth)
      VStack(alignment: .leading, spacing: 1) {
        Text(title)
          .lineLimit(1)
          .truncationMode(entry.isTranscript ? .middle : .tail)
        Text("\(details) · \(time)")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .monospacedDigit()
          .lineLimit(1)
      }
      Spacer(minLength: 4)
      Menu {
        actions
      } label: {
        Label("Actions", systemImage: "ellipsis")
          .labelStyle(.iconOnly)
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .foregroundStyle(.secondary)
      .help("Actions")
      // VoiceOver reaches the same actions on the row itself.
      .accessibilityHidden(true)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(title), \(details), \(dayTitle) at \(time)")
    .accessibilityHint(entry.needsTranscription ? "Transcribes the recording" : "Opens the transcript")
    // The menu's actions, offered to VoiceOver on the row itself.
    .accessibilityActions { actions }
  }
}

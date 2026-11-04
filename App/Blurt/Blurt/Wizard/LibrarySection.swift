import Accessibility
import AppKit
import BlurtEngine
import SwiftUI

/// The ready screen's Library: every saved recording, dictation, file and
/// spoken answer, searchable, filtered by kind, and grouped under day headings.
/// A stock plain `List` on a grouped form section's fill: native selection supports
/// double-click/Return to open, ⌘C to copy, Delete to confirm deletion, and ⌘F
/// to search; the contextual menu holds each entry's actions.
struct LibrarySection: View {
  var coordinator: AppCoordinator
  let triggerKey: TriggerKey
  let activation: TriggerActivation

  /// The list's tallest: about six two-line rows and their day headings,
  /// then it scrolls.
  private static let maxListHeight: CGFloat = 300
  /// The list's shortest: room for the empty prompt or a no-results message.
  private static let minListHeight: CGFloat = 132
  /// A two-line row and a day heading, as a plain list draws them.
  private static let rowHeight: CGFloat = 44
  private static let headingHeight: CGFloat = 28

  /// The list's height: fitted to the whole library — its rows and day
  /// headings — between `minListHeight` and `maxListHeight`, so a short
  /// library doesn't sit atop an empty panel. Sized from the history rather
  /// than what the filter or search shows, so the panel keeps one shape while
  /// they change. Only the entries that could fit are walked.
  static func listHeight(for history: [SavedTranscript]) -> CGFloat {
    let calendar = Calendar.current
    let visible = history.prefix(Int(maxListHeight / rowHeight) + 1)
    let headings = Set(visible.map { calendar.startOfDay(for: $0.date) }).count
    let content = CGFloat(visible.count) * rowHeight + CGFloat(headings) * headingHeight
    return min(max(content, minListHeight), maxListHeight)
  }

  @State private var query = ""
  @State private var filter = LibraryFilter.all
  @State private var selection: SavedTranscript.ID?
  @State private var pendingDelete: SavedTranscript?
  @State private var searchFocusRequest = 0
  /// The history, filtered and under its day headings: rebuilt only when the
  /// history, the filter or the search changes — not on every selection
  /// change or play/stop, which also redraw this view, and which would
  /// otherwise re-run a full-text search across every saved transcript.
  @State private var days: [LibraryDay] = []
  /// The search `days` was last built for — what the empty-list message
  /// describes, so it can't run ahead of the list during the typing pause.
  @State private var shownQuery: String?
  /// Each entry's row details, by id, with what they were worked out from.
  /// Updated when the history changes — never per search keystroke — and an
  /// entry's are kept while its transcript and style are unchanged, since a
  /// word count walks the whole transcript and a long recording runs to tens
  /// of thousands of words. (A string compared with itself is a pointer check.)
  @State private var details: [SavedTranscript.ID: CachedDetails] = [:]

  private var model: TranscriptsModel { coordinator.transcripts }

  /// The search, trimmed; nil when there's nothing to search for.
  private var trimmedQuery: String? { query.trimmedNonEmpty() }

  /// The history, filtered: by kind, then by a case- and diacritic-blind match
  /// against the title, the transcript, an answer's request, and every fetched
  /// task result — field by field, stopping at the first match.
  private func filtered() -> [SavedTranscript] {
    let query = trimmedQuery
    return model.history.filter { entry in
      guard filter.includes(entry) else { return false }
      guard let query else { return true }
      return entry.title.localizedStandardContains(query) || entry.text.localizedStandardContains(query)
        || entry.request?.localizedStandardContains(query) == true
        || entry.results.values.contains { $0.localizedStandardContains(query) }
    }
  }

  private func refresh() {
    let cache = details
    days = LibraryDay.group(filtered(), now: .now) { cache[$0.id]?.text ?? LibraryDay.details(of: $0) }
    shownQuery = trimmedQuery
    // A selection the filter or search now hides is dropped, so Delete and
    // ⌘C can't act on an entry that isn't on screen.
    if let selected = selection, !days.contains(where: { $0.rows.contains { $0.entry.id == selected } }) {
      selection = nil
    }
  }

  /// Brings `details` up to date with the history: kept for an entry whose
  /// transcript and style are unchanged, worked out afresh otherwise. Ids are
  /// unique in a healthy history; a duplicate keeps the first rather than
  /// trapping.
  private func updateDetails() {
    let previous = details
    details = Dictionary(
      model.history.map { entry in
        let source = entry.plainText ?? entry.text
        if let cached = previous[entry.id], cached.source == source, cached.style == entry.style {
          return (entry.id, cached)
        }
        return (entry.id, CachedDetails(source: source, style: entry.style, text: LibraryDay.details(of: entry)))
      },
      uniquingKeysWith: { first, _ in first })
  }

  private func entry(id: SavedTranscript.ID?) -> SavedTranscript? {
    id.flatMap { id in model.history.first { $0.id == id } }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text("Library")
          .font(.headline)
          .accessibilityAddTraits(.isHeader)
        Spacer(minLength: 8)
        // Nothing to filter or search yet, so the controls wait for a first entry.
        if !model.history.isEmpty {
          SearchField(text: $query, prompt: "Search transcripts", focusRequest: searchFocusRequest)
            .frame(width: 180)
        }
      }
      if !model.history.isEmpty {
        filterPicker
      }
      list
        .frame(height: Self.listHeight(for: model.history))
        // The grouped form's section look, so the Library matches the panels
        // above it: a plain list on the form's fill, clipped to its radius.
        .background(Color(nsColor: .quaternarySystemFill), in: FormPanel.shape)
        .clipShape(FormPanel.shape)
    }
    .onChange(of: model.history, initial: true) {
      updateDetails()
      refresh()
    }
    // Re-headed at midnight, so "Today" doesn't keep yesterday's entries when
    // the window stays open overnight.
    .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged).receive(on: RunLoop.main)) { _ in
      refresh()
    }
    .onChange(of: filter) { refresh() }
    // The search waits for a pause in typing: each pass is a full-text match
    // across every saved transcript, on the main thread.
    .task(id: query) {
      guard (try? await Task.sleep(for: .milliseconds(150))) != nil else { return }
      refresh()
    }
    // Edit › Find (⌘F), for this window.
    .focusedSceneValue(\.focusHistorySearch, model.history.isEmpty ? nil : { searchFocusRequest += 1 })
    .deleteConfirmation(for: $pendingDelete, model: model) { deleted in
      // The next row takes the selection, as Mac lists do, so Delete
      // can carry on down the list.
      let rows = days.flatMap(\.rows).map(\.entry)
      guard selection == deleted.id, let index = rows.firstIndex(where: { $0.id == deleted.id }) else { return }
      let neighbors = rows.indices.contains(index + 1) ? rows[index + 1] : index > 0 ? rows[index - 1] : nil
      selection = neighbors?.id
    }
  }

  /// The kind filter, at its natural width — small, as at regular size its five
  /// segments outgrow the window.
  private var filterPicker: some View {
    Picker("Show", selection: $filter) {
      ForEach(LibraryFilter.allCases, id: \.self) { Text($0.title).tag($0) }
    }
    .pickerStyle(.segmented)
    .labelsHidden()
    .controlSize(.small)
    .fixedSize()
  }

  /// The list, always drawn so the window keeps one shape; an empty one
  /// carries its message over it.
  private var list: some View {
    List(selection: $selection) {
      ForEach(days) { day in
        Section(day.title) {
          ForEach(day.rows, id: \.entry.id) { row in
            let entry = row.entry
            HistoryRow(
              entry: entry, details: row.details, dayTitle: day.title,
              actions: EntryActions(entry: entry, model: model, delete: { pendingDelete = entry })
            )
            .tag(entry.id)
            // Two-line rows separate themselves, as in Mail; a plain list's
            // edge-to-edge rules wouldn't match the form's inset ones above.
            .listRowSeparator(.hidden)
          }
        }
      }
    }
    .listStyle(.plain)
    .listSectionSeparator(.hidden)
    .scrollContentBackground(.hidden)
    .accessibilityIdentifier(UITestIdentifiers.recentList)
    .overlay { emptyMessage }
    .contextMenu(forSelectionType: SavedTranscript.ID.self) { ids in
      if let entry = entry(id: ids.first) {
        EntryActions(entry: entry, model: model, delete: { pendingDelete = entry })
      }
    } primaryAction: { ids in
      // Double-click and Return.
      if let entry = entry(id: ids.first) { model.open(entry) }
    }
    .onCopyCommand {
      guard let entry = entry(id: selection) else { return [] }
      AccessibilityNotification.Announcement("Copied").post()
      return [NSItemProvider(object: entry.text as NSString)]
    }
    .onDeleteCommand { pendingDelete = entry(id: selection) }
  }

  @ViewBuilder private var emptyMessage: some View {
    if model.history.isEmpty {
      emptyPrompt
    } else if days.isEmpty, let shownQuery {
      EmptyListMessage(
        title: "No results for \u{201C}\(shownQuery)\u{201D}", systemImage: "magnifyingglass",
        hint: "Check the spelling or try a new search.")
    } else if days.isEmpty {
      EmptyListMessage(title: filter.emptyTitle, systemImage: filter.systemImage, hint: filter.emptyHint)
    }
  }

  /// The first-run prompt, naming both things this list will hold: a
  /// dictation (click a field, press the key) and a transcript (Record, or
  /// drop a file).
  private var emptyPrompt: some View {
    VStack(spacing: 6) {
      Text("Ready when you are")
        .font(.headline)
        .foregroundStyle(.primary)
      HStack(spacing: 4) {
        Text("Click a text field, then \(activation.startVerb)")
        KeyCap(label: triggerKey.keycapLabel)
        Text("to dictate")
      }
      Text("Press Record, or drop an audio file, to transcribe")
    }
    .font(.callout)
    .foregroundStyle(.secondary)
    .fixedSize()
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      "Ready when you are. Click a text field, then \(activation.startVerb) \(triggerKey.spokenName) to dictate. "
        + "Press Record, or drop an audio file, to transcribe."
    )
    .accessibilityAddTraits(.isStaticText)
    .accessibilityIdentifier(UITestIdentifiers.recentEmptyPrompt)
  }
}

/// An entry's actions — the list's contextual menu, and VoiceOver's actions on
/// the row.
private struct EntryActions: View {
  let entry: SavedTranscript
  let model: TranscriptsModel
  let delete: () -> Void

  var body: some View {
    Button("Open") { model.open(entry) }
    if entry.hasAudio {
      Button(model.isPlaying(entry) ? "Stop" : "Play") { model.togglePlayback(entry) }
    }
    Button("Copy") { NSPasteboard.copyAnnounced(entry.text) }
    // Gated on `hasAudio` and resolved on click: `audioURL` resolves a file's
    // bookmark, file-system work this menu is built too often to repeat.
    if entry.hasAudio {
      Button("Show in Finder") {
        if let url = entry.audioURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
      }
    }
    Divider()
    Button("Delete…", role: .destructive, action: delete)
  }
}

/// One saved entry as a two-line row: its kind's glyph, the title (the LLM's
/// for a recording, else the start of the text) over its details, and the time
/// of day — the day is the section heading. Opening is double-click or Return,
/// deleting is Delete, and the rest is the contextual menu, as in any Mac list.
private struct HistoryRow: View {
  let entry: SavedTranscript
  let details: String
  let dayTitle: String
  let actions: EntryActions

  var body: some View {
    let title = entry.title
    let time = entry.date.formatted(date: .omitted, time: .shortened)
    HStack {
      Label {
        VStack(alignment: .leading, spacing: 1) {
          Text(title)
            .lineLimit(1)
            .truncationMode(entry.isTranscript ? .middle : .tail)
          Text(details)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      } icon: {
        Image(systemName: LibraryKind(entry).systemImage)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 8)
      Text(time)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .fixedSize()
    }
    .padding(.vertical, 3)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(title), \(details), \(dayTitle) at \(time)")
    .accessibilityHint("Opens the transcript")
    // The contextual menu's actions, offered to VoiceOver on the row itself.
    .accessibilityActions { actions }
  }
}

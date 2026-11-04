import AppKit
import BlurtEngine
import SwiftUI

/// The ready screen's Library: every saved recording, dictation, file and
/// spoken answer, searchable, filtered by kind, and grouped under day headings.
/// White cards on the window's brand gradient, as Journal's entries: a click
/// opens one, its ⋯ menu and contextual menu hold its actions, and ⌘F searches.
struct LibrarySection: View {
  var coordinator: AppCoordinator
  let triggerKey: TriggerKey
  let activation: TriggerActivation

  /// The toolbar's search (`ReadyView`).
  let query: String
  /// The toolbar's Filter menu (`ReadyView`).
  let filter: LibraryFilter
  @State private var pendingDelete: SavedTranscript?
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

  var body: some View {
    Group {
      if days.isEmpty {
        emptyMessage
          .frame(maxWidth: .infinity, minHeight: 160)
          .card()
      } else {
        cards
      }
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
    .deleteConfirmation(for: $pendingDelete, model: model)
  }

  /// The entries as cards under their day headings, as Journal's — denser:
  /// a click opens one, its ⋯ menu and contextual menu hold the rest.
  private var cards: some View {
    LazyVStack(alignment: .leading, spacing: 8) {
      ForEach(days) { day in
        Text(day.title)
          .font(.headline)
          .padding(.top, 6)
          .padding(.leading, 4)
          .accessibilityAddTraits(.isHeader)
        ForEach(day.rows, id: \.entry.id) { row in
          let entry = row.entry
          let actions = EntryActions(entry: entry, model: model, delete: { pendingDelete = entry })
          HistoryRow(entry: entry, details: row.details, dayTitle: day.title, actions: actions)
            .padding(.horizontal, 14)
            // Optically even: the title's line keeps more space above its caps
            // than the details' keeps under its baseline, so the top takes 2
            // pt less than the bottom to look the same.
            .padding(.top, 9)
            .padding(.bottom, 11)
            .card()
            .contentShape(Rectangle())
            .onTapGesture { model.open(entry) }
            .contextMenu { actions }
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { model.open(entry) }
        }
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(UITestIdentifiers.recentList)
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
        KeyCap(label: triggerKey.spokenName)
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

/// One saved entry as a compact two-line row — Journal's entry card, much
/// denser: its kind's glyph, the title (the LLM's for a recording, else the
/// start of the text) over its details and time of day — the day is the
/// section heading — and a ⋯ menu of its actions, as each Journal entry has.
/// A click on the card opens it; the same actions are its contextual menu.
private struct HistoryRow: View {
  let entry: SavedTranscript
  let details: String
  let dayTitle: String
  let actions: EntryActions

  /// Wide enough for the widest kind glyph.
  private static let iconWidth: CGFloat = 20

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
    .accessibilityHint("Opens the transcript")
    // The menu's actions, offered to VoiceOver on the row itself.
    .accessibilityActions { actions }
  }
}

extension FocusedValues {
  /// Puts the cursor in the focused window's history search: what Edit › Find
  /// (⌘F) calls. Nil — and the menu item disabled — in a window without one.
  @Entry var focusHistorySearch: (() -> Void)?
  /// Opens the focused window's file panel to transcribe a file: what File ›
  /// Open… (⌘O) calls. Nil — and the menu item disabled — in a window without
  /// one.
  @Entry var importAudioFile: (() -> Void)?
}

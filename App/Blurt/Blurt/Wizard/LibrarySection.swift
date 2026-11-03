import Accessibility
import AppKit
import BlurtEngine
import SwiftUI

/// The ready screen's Library: every saved recording, dictation, file and
/// spoken answer, searchable, filtered by kind, and grouped under day headings.
/// A stock `List` with no styling of its own: native selection supports
/// double-click/Return to open, ⌘C to copy, Delete to confirm deletion, and ⌘F
/// to search; the contextual menu holds each entry's actions.
struct LibrarySection: View {
  var coordinator: AppCoordinator
  let triggerKey: TriggerKey
  let activation: TriggerActivation

  /// The list's height: about six two-line rows and their day headings,
  /// then it scrolls.
  private static let listHeight: CGFloat = 300

  @State private var query = ""
  @State private var filter = LibraryFilter.all
  @State private var selection: SavedTranscript.ID?
  @State private var pendingDelete: SavedTranscript?
  @State private var searchFocusRequest = 0
  /// The history, filtered (`filtered()`): recomputed only when the history,
  /// the filter or the search changes — not on every selection change or
  /// play/stop, which also redraw this view, and which would otherwise re-run
  /// a full-text search across every saved transcript.
  @State private var shown: [SavedTranscript] = []
  /// `shown` under its day headings, each row's details worked out — rebuilt
  /// with `shown` and for the same reason: a word count walks the whole
  /// transcript, and a long recording runs to tens of thousands of words.
  @State private var days: [LibraryDay] = []

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
    shown = filtered()
    days = LibraryDay.group(shown, now: .now)
  }

  /// The selected entry, if any.
  private var selectedEntry: SavedTranscript? {
    selection.flatMap { id in model.history.first { $0.id == id } }
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
        .frame(height: Self.listHeight)
    }
    .onChange(of: model.history, initial: true) { refresh() }
    .onChange(of: filter) { refresh() }
    .onChange(of: query) { refresh() }
    // Edit › Find (⌘F), for this window.
    .focusedSceneValue(\.focusHistorySearch, model.history.isEmpty ? nil : { searchFocusRequest += 1 })
    .deleteConfirmation(for: $pendingDelete, model: model) { deleted in
      // The next row takes the selection, as Mac lists do, so Delete
      // can carry on down the list.
      let rows = shown
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
              actions: { EntryActions(entry: entry, model: model, delete: { pendingDelete = entry }) }
            )
            .tag(entry.id)
          }
        }
      }
    }
    .listStyle(.inset)
    .accessibilityIdentifier(UITestIdentifiers.recentList)
    // A scroller that stays visible, so the depth past the fold shows.
    .scrollIndicators(.visible)
    .overlay { emptyMessage }
    .contextMenu(forSelectionType: SavedTranscript.ID.self) { ids in
      if let entry = entry(for: ids) {
        EntryActions(entry: entry, model: model, delete: { pendingDelete = entry })
      }
    } primaryAction: { ids in
      // Double-click and Return.
      if let entry = entry(for: ids) { model.open(entry) }
    }
    .onCopyCommand {
      guard let entry = selectedEntry else { return [] }
      AccessibilityNotification.Announcement("Copied").post()
      return [NSItemProvider(object: entry.text as NSString)]
    }
    .onDeleteCommand { pendingDelete = selectedEntry }
  }

  @ViewBuilder private var emptyMessage: some View {
    if model.history.isEmpty {
      emptyPrompt
    } else if shown.isEmpty, trimmedQuery != nil {
      EmptyListMessage(
        title: "No results for \u{201C}\(query)\u{201D}", systemImage: "magnifyingglass",
        hint: "Check the spelling or try a new search.")
    } else if shown.isEmpty {
      EmptyListMessage(title: filter.emptyTitle, systemImage: filter.systemImage, hint: filter.emptyHint)
    }
  }

  private func entry(for ids: Set<SavedTranscript.ID>) -> SavedTranscript? {
    guard let id = ids.first else { return nil }
    return model.history.first { $0.id == id }
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

/// The Library's filter: everything, or one family of entry.
private enum LibraryFilter: CaseIterable {
  case all, recordings, dictations, files, spoken

  var title: String {
    switch self {
    case .all: "All"
    case .recordings: "Recordings"
    case .dictations: "Dictations"
    case .files: "Files"
    case .spoken: "Spoken"
    }
  }

  /// The kinds shown.
  private var kinds: Set<LibraryKind> {
    switch self {
    case .all: Set(LibraryKind.allCases)
    case .recordings: [.recording]
    case .dictations: [.dictation]
    case .files: [.file]
    case .spoken: [.readAloud, .ask]
    }
  }

  func includes(_ entry: SavedTranscript) -> Bool { kinds.contains(LibraryKind(entry)) }

  var systemImage: String {
    switch self {
    case .all: "tray"
    case .recordings: LibraryKind.recording.systemImage
    case .dictations: LibraryKind.dictation.systemImage
    case .files: LibraryKind.file.systemImage
    case .spoken: LibraryKind.readAloud.systemImage
    }
  }

  var emptyTitle: String {
    switch self {
    case .all: "Nothing yet"
    case .recordings: "No recordings yet"
    case .dictations: "No dictations yet"
    case .files: "No files yet"
    case .spoken: "Nothing spoken yet"
    }
  }

  var emptyHint: String {
    switch self {
    case .all: ""
    case .recordings: "Press Record to capture a meeting or a voice memo."
    case .dictations: "Click a text field and press your dictation key."
    case .files: "Drop an audio or video file on this window."
    case .spoken: "Select text and press your read-aloud or ask key."
    }
  }
}

/// One day's entries under its heading — "Today", "Yesterday", a weekday
/// within the week, then the date — each with its row's details.
private struct LibraryDay: Identifiable {
  struct Row {
    let entry: SavedTranscript
    let details: String
  }

  let id: Date
  let title: String
  var rows: [Row]

  /// `entries` (newest first) split into runs by calendar day, order kept.
  static func group(_ entries: [SavedTranscript], now: Date) -> [LibraryDay] {
    let calendar = Calendar.current
    var days: [LibraryDay] = []
    for entry in entries {
      let day = calendar.startOfDay(for: entry.date)
      let row = Row(entry: entry, details: details(of: entry))
      if days.last?.id == day {
        days[days.count - 1].rows.append(row)
      } else {
        days.append(LibraryDay(id: day, title: title(for: day, now: now, calendar: calendar), rows: [row]))
      }
    }
    return days
  }

  /// Every branch reads the `now` it's given, so one grouping can't straddle
  /// midnight with two answers.
  private static func title(for day: Date, now: Date, calendar: Calendar) -> String {
    let today = calendar.startOfDay(for: now)
    let daysAgo = calendar.dateComponents([.day], from: day, to: today).day ?? 0
    switch daysAgo {
    case 0: return "Today"
    case 1: return "Yesterday"
    case 2..<7: return day.formatted(.dateTime.weekday(.wide))
    default:
      return calendar.isDate(day, equalTo: now, toGranularity: .year)
        ? day.formatted(.dateTime.month(.wide).day()) : day.formatted(date: .long, time: .omitted)
    }
  }

  /// "Dictation · Formal · 412 words", "Recording · 6,120 words", "Ask About
  /// Selection" — no count for a spoken entry, whose text is what was read
  /// rather than what was said.
  private static func details(of entry: SavedTranscript) -> String {
    let kind = LibraryKind(entry)
    let words: String? =
      switch (kind, entry.wordCount) {
      case (.readAloud, _), (.ask, _), (_, 0): nil
      case (_, 1): "1 word"
      case (_, let count): "\(count.formatted()) words"
      }
    return [kind.name, entry.style, words].compactMap { $0 }.joined(separator: " · ")
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
    if let url = entry.audioURL {
      Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }
    Divider()
    Button("Delete…", role: .destructive, action: delete)
  }
}

/// One saved entry as a two-line row: its kind's glyph, the title (the LLM's
/// for a recording, else the start of the text) over its details, and the time
/// of day — the day is the section heading. Opening is double-click or Return,
/// deleting is Delete, and the rest is the contextual menu, as in any Mac list.
private struct HistoryRow<Actions: View>: View {
  let entry: SavedTranscript
  let details: String
  let dayTitle: String
  @ViewBuilder var actions: () -> Actions

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
    .padding(.vertical, 1)
    .help("\(title)\n\(details) — double-click to open")
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(title), \(details), \(dayTitle) at \(time)")
    .accessibilityHint("Opens the transcript")
    // The contextual menu's actions, offered to VoiceOver on the row itself.
    .accessibilityActions(actions)
  }
}

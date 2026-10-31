import Accessibility
import AppKit
import BlurtEngine
import SwiftUI

/// Searchable history outside the form so the list can scroll independently.
/// Native selection supports double-click/Return to open, ⌘C to copy,
/// Delete to confirm deletion, and ⌘F to search.
struct RecentSection: View {
  var coordinator: AppCoordinator
  let triggerKey: TriggerKey
  let activation: TriggerActivation

  /// The list's height: about eight comfortably spaced rows, then it scrolls.
  private static let listHeight: CGFloat = 248

  @State private var query = ""
  @State private var filter = HistoryFilter.all
  @State private var selection: SavedTranscript.ID?
  @State private var pendingDelete: SavedTranscript?
  @State private var searchFocusRequest = 0

  private var model: TranscriptsModel { coordinator.transcripts }

  /// The search, trimmed; nil when there's nothing to search for.
  private var trimmedQuery: String? { query.trimmedNonEmpty() }

  /// The history, filtered: by kind, then by a case- and diacritic-blind match
  /// against the title, the transcript, an answer's request, and every fetched
  /// task result — field by field, stopping at the first match.
  private var shown: [SavedTranscript] {
    let query = trimmedQuery
    return model.history.filter { entry in
      guard filter.includes(entry.kind) else { return false }
      guard let query else { return true }
      return entry.title.localizedStandardContains(query) || entry.text.localizedStandardContains(query)
        || entry.request?.localizedStandardContains(query) == true
        || entry.results.values.contains { $0.localizedStandardContains(query) }
    }
  }

  /// The selected entry, if any.
  private var selectedEntry: SavedTranscript? {
    selection.flatMap { id in model.history.first { $0.id == id } }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      header
      content
        .frame(height: Self.listHeight)
        // The grouped form's section look, drawn here: this list lives
        // outside the form, whose table would otherwise swallow its scrolling.
        .background(Color(nsColor: .quaternarySystemFill), in: FormPanel.shape)
        .clipShape(FormPanel.shape)
    }
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

  /// Nothing to filter or search yet: the controls wait for a first entry.
  @ViewBuilder private var header: some View {
    if model.history.isEmpty {
      Text("Recent")
        .font(.headline)
        .padding(.horizontal, 10)
    } else {
      HStack(spacing: 6) {
        Picker("Show", selection: $filter) {
          ForEach(HistoryFilter.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        Spacer(minLength: 0)
        SearchField(text: $query, prompt: "Search", focusRequest: searchFocusRequest)
          .frame(minWidth: 88, maxWidth: 140)
      }
    }
  }

  @ViewBuilder private var content: some View {
    let shown = shown
    if model.history.isEmpty {
      emptyPrompt
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if shown.isEmpty, trimmedQuery != nil {
      EmptyListMessage(
        title: "No results for \u{201C}\(query)\u{201D}", systemImage: "magnifyingglass",
        hint: "Check the spelling or try a new search.")
    } else if shown.isEmpty {
      EmptyListMessage(title: filter.emptyTitle, systemImage: filter.systemImage, hint: filter.emptyHint)
    } else {
      List(shown, selection: $selection) { entry in
        HistoryRow(
          entry: entry, isSelected: selection == entry.id, isPlaying: model.isPlaying(entry),
          open: { model.open(entry) }, togglePlayback: { model.togglePlayback(entry) },
          delete: { pendingDelete = entry }
        )
        .tag(entry.id)
      }
      .listStyle(.plain)
      .accessibilityIdentifier(UITestIdentifiers.recentList)
      .scrollContentBackground(.hidden)
      // A scroller that stays visible, so the depth past the fold shows.
      .scrollIndicators(.visible)
      .contextMenu(forSelectionType: SavedTranscript.ID.self) { ids in
        if let entry = entry(for: ids) {
          Button("Open") { model.open(entry) }
          if entry.hasAudio {
            Button(model.isPlaying(entry) ? "Stop" : "Play") { model.togglePlayback(entry) }
          }
          Button("Copy") { NSPasteboard.copyAnnounced(entry.text) }
          if let url = entry.audioURL {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
          }
          Divider()
          Button("Delete…", role: .destructive) { pendingDelete = entry }
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
  }

  private func entry(for ids: Set<SavedTranscript.ID>) -> SavedTranscript? {
    guard let id = ids.first else { return nil }
    return model.history.first { $0.id == id }
  }

  /// The first-run prompt, naming both things this list will hold: a
  /// dictation (click a field, press the key) and a transcription (Record, or
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

/// The Recent list's filter: everything, or one family of entry.
private enum HistoryFilter: CaseIterable {
  case all, dictations, read, transcripts

  var title: String {
    switch self {
    case .all: "All"
    case .dictations: "Dictations"
    case .read: "Read Aloud"
    case .transcripts: "Transcripts"
    }
  }

  func includes(_ kind: SavedTranscript.Kind) -> Bool {
    switch self {
    case .all: true
    case .dictations: kind == .dictation
    case .read: kind == .readAloud
    case .transcripts: kind == .file || kind == .recording  // `SavedTranscript.isTranscript`
    }
  }

  var systemImage: String {
    switch self {
    case .all, .transcripts: "waveform"
    case .dictations: "keyboard"
    case .read: "speaker.wave.2"
    }
  }

  var emptyTitle: String {
    switch self {
    case .all: "Nothing yet"
    case .dictations: "No dictations yet"
    case .read: "Nothing read aloud yet"
    case .transcripts: "No transcripts yet"
    }
  }

  var emptyHint: String {
    switch self {
    case .all: ""
    case .dictations: "Click a text field and press your dictation key."
    case .read: "Select text and press your read-aloud key."
    case .transcripts: "Press Record, or drop an audio file on this window."
    }
  }
}

/// One saved transcript as a compact list row: a glyph for its
/// kind, the title (the LLM's for a recording, else the start of the text),
/// and a short age on the trailing edge. The full details — kind, style, the
/// spelled-out time — are what VoiceOver reads and the tooltip shows. No
/// controls in the row: opening is double-click or Return and deleting is
/// Delete, as in any Mac list, and Play is in the contextual menu and the
/// transcript sheet.
private struct HistoryRow: View {
  let entry: SavedTranscript
  let isSelected: Bool
  let isPlaying: Bool
  let open: () -> Void
  let togglePlayback: () -> Void
  let delete: () -> Void
  var body: some View {
    // The whole row in the timeline, so the tooltip's and VoiceOver's ages
    // advance with the visible one.
    TimelineView(.periodic(from: .now, by: RecentDictations.Entry.justNowThreshold / 2)) { timeline in
      row(now: timeline.date)
    }
  }

  private func row(now: Date) -> some View {
    let details = details(now: now)
    return HStack(spacing: 8) {
      Image(systemName: glyph)
        // The system's selection: on its accent highlight the accent glyph
        // would vanish, so a selected row's glyph takes the adaptive primary
        // style, white there and label-coloured on the grey unfocused one.
        .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(BlurtBrand.accent))
        .frame(width: 18)
        .accessibilityHidden(true)
      Text(entry.title)
        .font(.callout)
        .lineLimit(1)
        .truncationMode(entry.kind == .dictation ? .tail : .middle)
      Spacer(minLength: 8)
      // One line, a compact list row: the kind is the glyph (and the
      // filter), so only the time needs words.
      Text(Self.shortTime(of: entry.date, now: now))
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .fixedSize()
    }
    .padding(.vertical, 5)
    .contentShape(Rectangle())
    .help("\(entry.title)\n\(details) — double-click to open")
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(entry.title), \(details)")
    .accessibilityHint("Opens the transcript")
    // The contextual menu's actions, offered to VoiceOver on the row itself.
    .accessibilityActions {
      Button("Open", action: open)
      if entry.hasAudio { Button(isPlaying ? "Stop" : "Play", action: togglePlayback) }
      Button("Delete…", action: delete)
    }
  }

  /// The row's trailing time, kept short: "Now" for the first minute,
  /// then "17 min", "3 hr", then the day — "Yesterday", "Mon", "Oct 12".
  static func shortTime(of date: Date, now: Date) -> String {
    let elapsed = now.timeIntervalSince(date)
    if elapsed < RecentDictations.Entry.justNowThreshold { return "Now" }
    if elapsed < 3600 { return "\(Int(elapsed / 60)) min" }
    if Calendar.current.isDate(date, inSameDayAs: now) { return "\(Int(elapsed / 3600)) hr" }
    if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
    if elapsed < 6 * 86_400 { return date.formatted(.dateTime.weekday(.abbreviated)) }
    return date.formatted(.dateTime.month(.abbreviated).day())
  }

  private var glyph: String {
    switch entry.kind {
    case .dictation: "keyboard"
    case .file: "waveform"
    case .recording: "record.circle"
    case .readAloud: entry.request == nil ? "speaker.wave.2" : "questionmark.bubble"
    }
  }

  /// "Dictation · Formal · 2 minutes ago".
  private func details(now: Date) -> String {
    let kind =
      switch entry.kind {
      case .dictation: "Dictation"
      case .file: "File"
      case .recording: "Recording"
      case .readAloud: entry.request == nil ? "Read aloud" : "Answer"
      }
    // "less than 1 minute ago" for the first minute, then the system's
    // wording — the engine's rule (`relativeLabel`), with this list's phrase.
    let age = RecentDictations.Entry.relativeLabel(for: entry.date, now: now, justNow: "less than 1 minute ago")
    return [kind, entry.style, age]
      .compactMap { $0 }.joined(separator: " · ")
  }
}

/// An empty list's message, sized for this small panel: a glyph, a headline,
/// a callout hint — the scale of "Ready when you are", where the system's
/// `ContentUnavailableView` sets a full-window title.
private struct EmptyListMessage: View {
  let title: String
  let systemImage: String
  let hint: String

  var body: some View {
    VStack(spacing: 6) {
      Image(systemName: systemImage)
        .font(.title2)
        .foregroundStyle(.tertiary)
        .accessibilityHidden(true)
      Text(title)
        .font(.headline)
      if !hint.isEmpty {
        Text(hint)
          .font(.callout)
          .foregroundStyle(.secondary)
      }
    }
    .multilineTextAlignment(.center)
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityElement(children: .combine)
  }
}

/// The look of a grouped form's section, for the panels drawn outside the
/// form (the drop well, the Recent list): one shape, so they stay matched to
/// the form and to each other.
enum FormPanel {
  static let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
}

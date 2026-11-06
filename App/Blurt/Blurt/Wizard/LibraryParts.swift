import BlurtEngine
import SwiftUI

// Pieces of the ready screen's Library.

/// What a Library entry is, as the window draws it — the one table of each
/// kind's name and glyph, read by the Library's rows and its filter. An answer
/// is its own kind here, though the store files it as a read-aloud with a
/// request.
enum LibraryKind {
  case recording, dictation, file, readAloud, ask

  init(_ entry: SavedTranscript) {
    switch entry.kind {
    case .recording: self = .recording
    case .dictation: self = .dictation
    case .file: self = .file
    case .readAloud: self = entry.request == nil ? .readAloud : .ask
    }
  }

  var name: String {
    switch self {
    case .recording: "Recording"
    case .dictation: "Dictation"
    case .file: "File"
    case .readAloud: KeyActionName.readAloud
    case .ask: KeyActionName.ask
    }
  }

  var systemImage: String {
    switch self {
    case .recording: "mic"
    case .dictation: "text.alignleft"
    case .file: "doc"
    case .readAloud: "speaker.wave.2"
    case .ask: "questionmark.bubble"
    }
  }
}

/// The Library's filter: everything, or one family of entry.
enum LibraryFilter: CaseIterable {
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

  func includes(_ entry: SavedTranscript) -> Bool {
    switch self {
    case .all: true
    case .recordings: entry.kind == .recording
    case .dictations: entry.kind == .dictation
    case .files: entry.kind == .file
    case .spoken: entry.kind == .readAloud
    }
  }

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

/// A row's details, with the transcript and style they were worked out from.
struct CachedDetails {
  let source: String
  let style: String?
  let text: String
}

/// One day's entries under its heading — "Today", "Yesterday", a weekday
/// within the week, then the date — each with its row's details.
struct LibraryDay: Identifiable {
  struct Row {
    let entry: SavedTranscript
    let details: String
  }

  let id: Date
  let title: String
  var rows: [Row]

  /// `entries` (newest first) split into runs by calendar day, order kept,
  /// each row's details from `details`.
  static func group(
    _ entries: [SavedTranscript], now: Date, details: (SavedTranscript) -> String
  ) -> [LibraryDay] {
    let calendar = Calendar.current
    var days: [LibraryDay] = []
    for entry in entries {
      let day = calendar.startOfDay(for: entry.date)
      let row = Row(entry: entry, details: details(entry))
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
  static func details(of entry: SavedTranscript) -> String {
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

/// An empty list's message, sized for this small panel: a glyph, a headline,
/// a callout hint — the scale of "Ready when you are", where the system's
/// `ContentUnavailableView` sets a full-window title.
struct EmptyListMessage: View {
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

import BlurtEngine
import Foundation

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
  ) -> [Self] {
    let calendar = Calendar.current
    var days: [Self] = []
    for entry in entries {
      let day = calendar.startOfDay(for: entry.date)
      let row = Row(entry: entry, details: details(entry))
      if days.last?.id == day {
        days[days.count - 1].rows.append(row)
      } else {
        days.append(Self(id: day, title: title(for: day, now: now, calendar: calendar), rows: [row]))
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
    case 0:
      return "Today"

    case 1:
      return "Yesterday"

    case 2..<7:
      return day.formatted(.dateTime.weekday(.wide))

    default:
      return calendar.isDate(day, equalTo: now, toGranularity: .year)
        ? day.formatted(.dateTime.month(.wide).day()) : day.formatted(date: .long, time: .omitted)
    }
  }

  /// "Dictation · Formal · 412 words", "Recording · 6,120 words", "Ask About
  /// Selection" — no count for a spoken entry, whose text is what was read
  /// rather than what was said; "Recording · Not transcribed" for one whose
  /// transcription failed.
  static func details(of entry: SavedTranscript) -> String {
    let kind = LibraryKind(entry)
    let words: String? =
      switch (kind, entry.wordCount) {
      case (.readAloud, _), (.ask, _), (_, 0):
        nil

      case (_, 1):
        "1 word"

      case (_, let count):
        "\(count.formatted()) words"
      }
    let status = entry.needsTranscription ? "Not transcribed" : words
    return [kind.name, entry.style, status].compactMap(\.self).joined(separator: " · ")
  }
}

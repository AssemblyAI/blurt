public import Foundation

/// The saved history: one JSON array, newest first, every entry kept. Read
/// once at launch and rewritten whole on each change — text only, so even
/// thousands of entries stay a few megabytes.
public struct TranscriptStore: Sendable {
  /// One entry of the list, or nil if it won't decode.
  private struct Lossy: Decodable {
    let value: SavedTranscript?

    init(from decoder: any Decoder) { value = try? SavedTranscript(from: decoder) }
  }

  /// `~/Library/Application Support/<data directory>/history.json` — `Blurt`,
  /// or `Blurt Dev` for a debug build (`HostIdentity.dataDirectoryName`).
  public static var defaultURL: URL {
    URL.applicationSupportDirectory
      .appending(path: HostIdentity.current.dataDirectoryName, directoryHint: .isDirectory)
      .appending(path: "history.json")
  }

  /// Where the main window's recordings are written, beside the history that
  /// points at them: `…/<data directory>/Recordings`.
  public static var recordingsDirectory: URL {
    defaultURL.deletingLastPathComponent().appending(path: "Recordings", directoryHint: .isDirectory)
  }

  /// Where read-aloud clips are kept: `…/<data directory>/Read Aloud`.
  public static var readAloudDirectory: URL {
    defaultURL.deletingLastPathComponent().appending(path: "Read Aloud", directoryHint: .isDirectory)
  }

  private let url: URL

  public init(url: URL = Self.defaultURL) {
    self.url = url
  }

  /// "Recording 2026-10-30 at 10.04.08.123.m4a" — a recording's file, named
  /// the way macOS names a screenshot, so recordings sort by time and read like
  /// the system's own.
  public static func recordingFileName(at date: Date) -> String {
    "Recording \(fileStamp(date)).m4a"
  }

  /// "Read 2026-10-30 at 10.04.08.123.wav" — a read-aloud clip's file, beside
  /// the recordings and named the same way.
  static func readAloudClipFileName(at date: Date) -> String {
    "Read \(fileStamp(date)).wav"
  }

  /// "2026-10-30 at 10.04.08.123" — how recordings and read-aloud clips are
  /// named: sortable, readable like the system's screenshots, and to the
  /// millisecond, so two in one second never share a file.
  public static func fileStamp(_ date: Date) -> String {
    date.formatted(
      Date.VerbatimFormatStyle(
        format:
          "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) at \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)).\(minute: .twoDigits).\(second: .twoDigits).\(secondFraction: .fractional(3))",
        timeZone: .current,
        calendar: Calendar(identifier: .gregorian)
      )
    )
  }

  /// Every saved transcript, newest first; empty when there is no file yet.
  ///
  /// Decoded an entry at a time, so one that won't decode — a kind a newer
  /// build wrote, read by an older one — costs that entry, not the history.
  /// When any are skipped the file is copied aside first
  /// (`history.backup-<date>.json`), since the next save drops them. A file
  /// that isn't a list at all is moved aside (`history.corrupt-<date>.json`)
  /// rather than left for the next save to overwrite.
  public func load() -> [SavedTranscript] {
    guard let data = try? Data(contentsOf: url) else {
      return []
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let stamp = Int(Date().timeIntervalSince1970)
    guard let entries = try? decoder.decode([Lossy].self, from: data) else {
      try? FileManager.default.moveItem(at: url, to: aside("corrupt-\(stamp)"))
      return []
    }
    let kept = entries.compactMap(\.value)
    if kept.count < entries.count {
      try? FileManager.default.copyItem(at: url, to: aside("backup-\(stamp)"))
    }
    return kept
  }

  private func aside(_ tag: String) -> URL {
    url.deletingPathExtension().appendingPathExtension("\(tag).json")
  }

  /// Replaces the saved list with `entries`, newest first.
  public func save(_ entries: [SavedTranscript]) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(entries).write(to: url, options: .atomic)
  }
}

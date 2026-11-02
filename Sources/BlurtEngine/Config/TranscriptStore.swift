import Foundation

/// One saved transcript — a dictation, a read-aloud clip, a file the user
/// brought, or a recording made with Record — as the main window's Recent list
/// shows it and the transcript sheet opens it. One shape for every kind, so the
/// history is one list kept one way.
///
/// **Every one is kept, on disk.** That includes dictations, which until
/// 2026-10-30 lived only in `RecentDictations`'s in-memory ring. The ring is
/// unchanged and still the only source of a dictation request's context
/// (`stt_prompt`); this store is the user's history, and nothing here is ever
/// sent as context. A dictation the session declined to remember — one made
/// into a secure field — never reaches the ring, so it is never saved either.
public struct SavedTranscript: Codable, Identifiable, Equatable, Sendable {
  public enum Kind: String, Codable, Sendable {
    case dictation
    /// A file dropped on the window or picked with Browse….
    case file
    /// A recording made with the Record button, in `TranscriptStore.recordingsDirectory`.
    case recording
    /// A read-aloud clip, in `TranscriptStore.readAloudDirectory`: the text
    /// read and the audio as it played.
    case readAloud
  }

  public let id: UUID
  public let kind: Kind
  public let date: Date
  /// The transcript: what was pasted for a dictation, the verbatim (and, with
  /// several speakers, labelled) text for a file or recording.
  public var text: String
  /// The audio it came from, for a file or recording; nil for a dictation,
  /// whose audio is never kept.
  public let fileURL: URL?
  /// For a file the user brought, a bookmark to it: it follows the file through
  /// a move or rename, which a path doesn't (`audioURL`). Blurt's own
  /// recordings and clips stay in its folder, so their path is enough.
  public let fileBookmark: Data?
  /// The custom style a dictation was made with (`RecentDictations.Entry.style`).
  public let style: String?
  /// For a read-aloud answer, the spoken request it replied to.
  public let request: String?
  /// The transcript without speaker labels, for a file or recording that had
  /// them; `text` is the labelled one, and what opens.
  public var plainText: String?
  /// A short title the LLM wrote for a file or recording
  /// (`TranscriptLLM.title(for:)`), shown in place of its file name.
  public var generatedTitle: String?
  /// Fetched transforms, keyed by the host's own facet names. Opaque here: the
  /// host owns which transforms exist and what they are called.
  public var results: [String: String]
  /// The custom request behind `results`' custom entry, if any.
  public var customRequest: String?

  public init(
    id: UUID = UUID(), kind: Kind, date: Date, text: String, fileURL: URL? = nil, style: String? = nil,
    request: String? = nil, plainText: String? = nil, generatedTitle: String? = nil, results: [String: String] = [:],
    customRequest: String? = nil
  ) {
    self.id = id
    self.kind = kind
    self.date = date
    self.text = text
    self.fileURL = fileURL
    self.fileBookmark = kind == .file ? try? fileURL?.bookmarkData() : nil
    self.style = style
    self.request = request
    // Kept only where it differs: identical, it's no second view of anything.
    self.plainText = plainText == text ? nil : plainText
    self.generatedTitle = generatedTitle
    self.results = results
    self.customRequest = customRequest
  }

  /// Whether the entry keeps audio of its own to play. A dictation never
  /// does: its audio isn't kept, so it has no file.
  public var hasAudio: Bool { fileURL != nil }

  /// Where the audio is now: a user's file found through its bookmark, so a
  /// moved or renamed file still plays and shows in Finder; otherwise the
  /// saved path.
  public var audioURL: URL? {
    guard let fileBookmark else { return fileURL }
    var isStale = false
    return (try? URL(resolvingBookmarkData: fileBookmark, bookmarkDataIsStale: &isStale)) ?? fileURL
  }

  /// Whether the audio is Blurt's own — a recording or a read-aloud clip —
  /// and so deleted with the entry; a file the user brought stays theirs.
  public var ownsAudio: Bool { kind == .recording || kind == .readAloud }

  /// A transcription of audio — a file or a recording — as opposed to a
  /// dictation or a reading: what gets an LLM title and speaker turns.
  public var isTranscript: Bool { kind == .file || kind == .recording }

  /// Replaces the transcript with a better one (a recording's diarized pass),
  /// keeping the plain text only where it differs, as `init` does.
  public mutating func replaceTranscript(_ text: String, plain: String) {
    self.text = text
    plainText = plain == text ? nil : plain
  }

  /// What a row and the sheet's header call it: for a file or recording, the
  /// LLM's title once it has one, else the file's name; otherwise the start of
  /// the text — what was said, or read.
  public var title: String {
    switch kind {
    case .file, .recording: generatedTitle ?? fileURL?.lastPathComponent ?? text
    case .dictation, .readAloud: text
    }
  }
}

/// The saved history: one JSON array, newest first, every entry kept. Read
/// once at launch and rewritten whole on each change — text only, so even
/// thousands of entries stay a few megabytes.
public struct TranscriptStore: Sendable {
  /// `~/Library/Application Support/<product>/history.json`.
  public static var defaultURL: URL {
    URL.applicationSupportDirectory
      .appending(path: HostIdentity.current.productName, directoryHint: .isDirectory)
      .appending(path: "history.json")
  }

  /// Where the main window's recordings are written, beside the history that
  /// points at them: `~/Library/Application Support/<product>/Recordings`.
  public static var recordingsDirectory: URL {
    defaultURL.deletingLastPathComponent().appending(path: "Recordings", directoryHint: .isDirectory)
  }

  /// Where read-aloud clips are kept: `…/<product>/Read Aloud`.
  public static var readAloudDirectory: URL {
    defaultURL.deletingLastPathComponent().appending(path: "Read Aloud", directoryHint: .isDirectory)
  }

  private let url: URL

  public init(url: URL = TranscriptStore.defaultURL) {
    self.url = url
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
    guard let data = try? Data(contentsOf: url) else { return [] }
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

  /// One entry of the list, or nil if it won't decode.
  private struct Lossy: Decodable {
    let value: SavedTranscript?
    init(from decoder: any Decoder) throws { value = try? SavedTranscript(from: decoder) }
  }

  /// "2026-10-30 at 10.04.08.123" — how recordings and read-aloud clips are
  /// named: sortable, readable like the system's screenshots, and to the
  /// millisecond, so two in one second never share a file.
  public static func fileStamp(_ date: Date) -> String {
    date.formatted(
      Date.VerbatimFormatStyle(
        format:
          "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) at \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)).\(minute: .twoDigits).\(second: .twoDigits).\(secondFraction: .fractional(3))",
        timeZone: .current, calendar: Calendar(identifier: .gregorian)))
  }

  /// Replaces the saved list with `entries`, newest first.
  public func save(_ entries: [SavedTranscript]) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(entries).write(to: url, options: .atomic)
  }
}

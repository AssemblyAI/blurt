public import Foundation

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
    /// read and the audio as it played. Its raw value, the case name, is the
    /// persisted history's spelling.
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

  /// Whether the entry keeps audio of its own to play. A dictation never
  /// does: its audio isn't kept, so it has no file.
  public var hasAudio: Bool { fileURL != nil }

  /// Where the audio is now: a user's file found through its bookmark, so a
  /// moved or renamed file still plays and shows in Finder; otherwise the
  /// saved path.
  public var audioURL: URL? {
    guard let fileBookmark else {
      return fileURL
    }
    var isStale = false
    return (try? URL(resolvingBookmarkData: fileBookmark, bookmarkDataIsStale: &isStale)) ?? fileURL
  }

  /// Whether the audio is Blurt's own — a recording or a read-aloud clip —
  /// and so deleted with the entry; a file the user brought stays theirs.
  public var ownsAudio: Bool { kind == .recording || kind == .readAloud }

  /// A transcription of audio — a file or a recording — as opposed to a
  /// dictation or a reading: what gets an LLM title and speaker turns.
  public var isTranscript: Bool { kind == .file || kind == .recording }

  /// A recording kept with no transcript yet: its transcription failed
  /// (offline, a server error) or found no speech, so it is saved with its
  /// audio and no text, for the Library to offer it again rather than lose it.
  public var needsTranscription: Bool { kind == .recording && hasAudio && text.isEmpty }

  /// What a row and the sheet's header call it: for a file or recording, the
  /// LLM's title once it has one, else the file's name; otherwise the start of
  /// the text — what was said, or read.
  public var title: String {
    switch kind {
    case .file, .recording:
      generatedTitle ?? fileURL?.lastPathComponent ?? text

    case .dictation, .readAloud:
      text
    }
  }

  /// The transcript's length in words, counted on the plain text where there
  /// is one so a recording's "Speaker A:" labels don't pad it.
  public var wordCount: Int { (plainText ?? text).wordCount }

  public init(
    kind: Kind,
    date: Date,
    text: String,
    id: UUID = UUID(),
    fileURL: URL? = nil,
    style: String? = nil,
    request: String? = nil,
    plainText: String? = nil,
    generatedTitle: String? = nil,
    results: [String: String] = [:],
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

  /// Replaces the transcript with a better one (a recording's diarized pass),
  /// keeping the plain text only where it differs, as `init` does.
  public mutating func replaceTranscript(_ text: String, plain: String) {
    self.text = text
    plainText = plain == text ? nil : plain
  }
}

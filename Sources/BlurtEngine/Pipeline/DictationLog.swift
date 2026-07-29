import Foundation

/// Append-only JSONL log of completed dictations — the transcript that came
/// back and every request field that was sent to get it — at
/// `~/Library/Logs/Blurt/dictations.jsonl`. Used to build a real-world
/// corpus for prompt iteration. Written only while developer mode is switched
/// on (`DeveloperModeStore` — the Settings window's Developer section, which
/// also displays this path), so a user who never opts in has no dictation
/// text on disk.
public enum DictationLog {
  /// One logged dictation: what came back (`transcript`), when, and exactly what
  /// was sent to steer it. Fields carry the request's own wire names so a log
  /// line reads as the request it describes.
  ///
  /// Only what was *sent* is recorded. The captured-but-unsent focus context —
  /// app and field names, the window title, selected text — deliberately stays
  /// off disk. Prior-cursor text is on the sent side of that line now that it
  /// rides as `conversation_context`; what keeps a password out of it is
  /// `FocusCapture`, which skips prior and selected text in secure fields
  /// entirely (failing closed when the AX role can't be read), so it never
  /// reaches a context in the first place.
  struct Entry: Encodable {
    let transcript: String
    let ts: String
    /// The steering fields sent to AssemblyAI for this utterance. Built here
    /// from `context` (rather than threaded through from the transcriber) so the
    /// log always reflects what was actually sent, even for calls that construct
    /// an entry directly from a context.
    let conversationContext: [String]
    let keytermsPrompt: [String]
    let llmInstruction: String?

    enum CodingKeys: String, CodingKey {
      case transcript
      case ts
      case conversationContext = "conversation_context"
      case keytermsPrompt = "keyterms_prompt"
      case llmInstruction = "llm_instruction"
    }

    /// Mirrors `DictationConfig.encode(to:)`: an empty array omits its field, so
    /// a line states only what the request actually carried.
    func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(transcript, forKey: .transcript)
      try container.encode(ts, forKey: .ts)
      if !conversationContext.isEmpty {
        try container.encode(conversationContext, forKey: .conversationContext)
      }
      if !keytermsPrompt.isEmpty {
        try container.encode(keytermsPrompt, forKey: .keytermsPrompt)
      }
      try container.encodeIfPresent(llmInstruction, forKey: .llmInstruction)
    }
  }

  /// Where the log lives. Public so the Settings window's Developer section
  /// can display the path next to the switch that enables writing to it. The
  /// file (and its directory) are only created when the first entry is
  /// appended, so reading this never touches the disk.
  public static let defaultURL = URL.libraryDirectory.appending(path: "Logs/Blurt/dictations.jsonl")

  /// `defaultURL` as a home-abbreviated path (`~/Library/Logs/…`) for the label
  /// beside the developer-mode switch. Derived here, next to the URL the writer
  /// actually uses, so the displayed path can't drift from where the log lands —
  /// and so the `NSString` bridge this needs stays out of a SwiftUI view.
  public static var defaultDisplayPath: String {
    (defaultURL.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
  }

  // .sortedKeys keeps the on-disk JSONL deterministic (stable diff for tests
  // and post-hoc grep).
  static func makeEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }

  static let timestampFormat = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

  // Appends run on this serial queue rather than the caller's thread. The
  // public entry point is invoked from the `DictationSession` actor mid-
  // pipeline; doing the synchronous FileHandle I/O inline would briefly block
  // the actor. The queue is serial so entries stay append-ordered.
  //
  // Internal so a test can `sync {}` on it to drain a dispatched write, rather
  // than polling the filesystem and hoping.
  static let queue = DispatchQueue(label: "\(BlurtIdentity.subsystem).DictationLog")

  /// Append a completed transcript to the JSONL log. **Gated on developer mode:**
  /// with the switch off (the default) this returns without touching the disk, so
  /// callers can invoke it unconditionally. The actual file I/O is dispatched off
  /// the caller (see `queue`) so it never blocks the `DictationSession` actor.
  ///
  /// `store` and `url` exist to be overridden by tests: with both hard-coded, the
  /// gate — the switch's entire privacy guarantee — could only be exercised by
  /// writing to the real `~/Library/Logs`, so nothing covered it.
  static func append(
    transcript: String,
    context: TranscriptionContext? = nil,
    store: DeveloperModeStore = DeveloperModeStore(),
    to url: URL = defaultURL
  ) {
    guard store.isEnabled else { return }
    let now = Date()
    queue.async {
      write(transcript: transcript, context: context, to: url, now: now)
    }
  }

  /// The unconditional writer: formats one entry and appends it. Distinct name
  /// rather than an `append` overload so the gated entry point above can't be
  /// bypassed by accidentally satisfying a different signature.
  static func write(
    transcript: String, context: TranscriptionContext? = nil, to url: URL, now: Date
  ) {
    let steering = TranscriptionSteering.build(context: context)
    let entry = Entry(
      transcript: transcript, ts: now.formatted(timestampFormat),
      conversationContext: steering.conversationContext,
      keytermsPrompt: steering.keyterms,
      llmInstruction: steering.rewriteInstruction)
    guard var line = try? makeEncoder().encode(entry) else { return }
    line.append(0x0A)  // '\n'

    let path = url.path(percentEncoded: false)
    if !FileManager.default.fileExists(atPath: path) {
      try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      FileManager.default.createFile(atPath: path, contents: nil)
    }
    guard let handle = try? FileHandle(forWritingTo: url) else { return }
    defer { try? handle.close() }
    _ = try? handle.seekToEnd()
    try? handle.write(contentsOf: line)
  }
}

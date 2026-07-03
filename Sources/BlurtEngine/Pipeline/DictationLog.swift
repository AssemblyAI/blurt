import Foundation

/// Append-only JSONL log of (raw STT, polished) pairs at
/// `~/Library/Logs/Blurt/dictations.jsonl`. Used to build a real-world
/// corpus for prompt iteration.
enum DictationLog {
  struct Entry: Encodable {
    let polished: String
    let raw: String
    let ts: String
    /// Focused-app topic hint sent as context, when one was captured.
    let app: String?
    /// Focused-window title sent as a topic hint, when one was captured.
    let window: String?
    /// Focused-field label sent as context, when one was captured.
    let field: String?
    /// Text-before-cursor "prior chunk context" sent, when any was captured.
    /// Lets you verify accessibility-tree prior-text reading actually fired.
    let prior: String?
    /// Selected text sent as context (the dictation replaced it), when any.
    let selected: String?
  }

  static let defaultURL: URL = {
    let dir = URL.libraryDirectory.appending(path: "Logs/Blurt", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appending(path: "dictations.jsonl")
  }()

  // .sortedKeys keeps the on-disk JSONL deterministic (stable diff for tests
  // and post-hoc grep).
  static func makeEncoder() -> JSONEncoder {
    let e = JSONEncoder()
    e.outputFormatting = [.sortedKeys]
    return e
  }

  static let timestampFormat = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

  #if DEBUG
    // Appends run on this serial queue rather than the caller's thread. The
    // public entry point is invoked from the `DictationSession` actor mid-
    // pipeline; doing the synchronous FileHandle I/O inline would briefly block
    // the actor. The queue is serial so entries stay append-ordered.
    private static let queue = DispatchQueue(label: "\(BlurtIdentity.subsystem).DictationLog")
  #endif

  /// Append a (raw, polished) entry to the JSONL log. **Debug-only:** the
  /// body is compiled out of Release builds; callers can invoke this
  /// unconditionally and pay zero cost when shipping. The actual file I/O is
  /// dispatched off the caller (see `queue`) so it never blocks the
  /// `DictationSession` actor.
  static func append(raw: String, polished: String, context: TranscriptionContext? = nil) {
    #if DEBUG
      let now = Date()
      queue.async {
        append(raw: raw, polished: polished, context: context, to: defaultURL, now: now)
      }
    #endif
  }

  static func append(
    raw: String, polished: String, context: TranscriptionContext? = nil, to url: URL, now: Date
  ) {
    let entry = Entry(
      polished: polished, raw: raw, ts: now.formatted(timestampFormat),
      app: context?.appName, window: context?.windowTitle, field: context?.fieldLabel,
      prior: context?.priorText, selected: context?.selectedText)
    guard var line = try? makeEncoder().encode(entry) else { return }
    line.append(0x0A)  // '\n'

    let path = url.path(percentEncoded: false)
    if !FileManager.default.fileExists(atPath: path) {
      FileManager.default.createFile(atPath: path, contents: nil)
    }
    guard let handle = try? FileHandle(forWritingTo: url) else { return }
    defer { try? handle.close() }
    _ = try? handle.seekToEnd()
    try? handle.write(contentsOf: line)
  }
}

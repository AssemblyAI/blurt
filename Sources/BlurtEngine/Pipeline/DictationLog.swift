import Foundation

/// Append-only JSONL log of completed transcripts at
/// `~/Library/Logs/Blurt/dictations.jsonl`. Used to build a real-world
/// corpus for prompt iteration. Written only while developer mode is switched
/// on (`DeveloperModeStore` — the Settings window's Developer section, which
/// also displays this path), so a user who never opts in has no dictation
/// text on disk.
public enum DictationLog {
  struct Entry: Encodable {
    let transcript: String
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
    /// The fully-assembled `config.prompt` sent to AssemblyAI for this
    /// utterance. Built here from `context` (rather than threaded through from
    /// the transcriber) so the log always reflects what was actually sent,
    /// even for calls that construct an entry directly from a context.
    let prompt: String?
  }

  /// Where the log lives. Public so the Settings window's Developer section
  /// can display the path next to the switch that enables writing to it. The
  /// file (and its directory) are only created when the first entry is
  /// appended, so reading this never touches the disk.
  public static let defaultURL = URL.libraryDirectory.appending(path: "Logs/Blurt/dictations.jsonl")

  // .sortedKeys keeps the on-disk JSONL deterministic (stable diff for tests
  // and post-hoc grep).
  static func makeEncoder() -> JSONEncoder {
    let e = JSONEncoder()
    e.outputFormatting = [.sortedKeys]
    return e
  }

  static let timestampFormat = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

  // Appends run on this serial queue rather than the caller's thread. The
  // public entry point is invoked from the `DictationSession` actor mid-
  // pipeline; doing the synchronous FileHandle I/O inline would briefly block
  // the actor. The queue is serial so entries stay append-ordered.
  private static let queue = DispatchQueue(label: "\(BlurtIdentity.subsystem).DictationLog")

  /// Append a completed transcript to the JSONL log. **Gated on developer
  /// mode:** with the switch off (the default) this returns without touching
  /// the disk, so callers can invoke it unconditionally. The actual file I/O is
  /// dispatched off the caller (see `queue`) so it never blocks the
  /// `DictationSession` actor.
  static func append(transcript: String, context: TranscriptionContext? = nil) {
    guard DeveloperModeStore().isEnabled else { return }
    let now = Date()
    queue.async {
      append(transcript: transcript, context: context, to: defaultURL, now: now)
    }
  }

  static func append(
    transcript: String, context: TranscriptionContext? = nil, to url: URL, now: Date
  ) {
    let entry = Entry(
      transcript: transcript, ts: now.formatted(timestampFormat),
      app: context?.appName, window: context?.windowTitle, field: context?.fieldLabel,
      prior: context?.priorText, selected: context?.selectedText,
      prompt: TranscriptionPrompt.build(context: context))
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

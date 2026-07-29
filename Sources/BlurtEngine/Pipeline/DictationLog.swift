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
    /// Focused-app display name, when one was captured.
    let app: String?
    /// Focused-app bundle identifier, when one was captured. The input the
    /// prompt's app-kind guidance (`AppKindPriming`) keys on, logged so the
    /// corpus shows *why* a prompt carried (or lacked) a guidance sentence.
    let bundle: String?
    /// Focused-window title, when one was captured (in a code editor it names
    /// the open file, which is what refines the prompt's instruction).
    let window: String?
    /// Focused-field label sent as context, when one was captured.
    let field: String?
    /// Text before the cursor at press time, when any was captured. Lets you
    /// verify accessibility-tree prior-text reading actually fired.
    let prior: String?
    /// Selected text at press time (the dictation replaced it), when any.
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
    let entry = Entry(
      transcript: transcript, ts: now.formatted(timestampFormat),
      app: context?.appName, bundle: context?.bundleID,
      window: context?.windowTitle, field: context?.fieldLabel,
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

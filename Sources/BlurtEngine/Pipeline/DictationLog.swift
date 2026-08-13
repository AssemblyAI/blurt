import Foundation
import os

/// Append-only JSONL log of completed transcripts at
/// `~/Library/Logs/Blurt/dictations.jsonl`. Used to build a real-world
/// corpus for prompt iteration. Written only while developer mode is switched
/// on (`DeveloperModeStore` — the Settings window's Developer section, which
/// also displays this path), so a user who never opts in has no dictation
/// text on disk.
///
/// Failed dictations go to a sibling `errors.jsonl` instead, behind the same
/// switch — see `DictationLog+Errors.swift`.
public enum DictationLog {
  struct Entry: Encodable {
    let transcript: String
    let ts: String
    /// Focused-app name, when one was captured. Local to this file — it is not
    /// part of the request.
    let app: String?
    /// Focused-window title, when one was captured. Local to this file.
    let window: String?
    /// Focused-field label, when one was captured. Local to this file.
    let field: String?
    /// Text-before-cursor "prior chunk context" sent as the request prompt, when
    /// any was captured. Lets you verify accessibility-tree prior-text reading
    /// actually fired.
    let prior: String?
    /// Selected text (the dictation replaced it), when any. Local to this file:
    /// it is captured for the paste path and recorded here, never sent.
    let selected: String?
    /// The fully-assembled `config.prompt` sent to AssemblyAI for this
    /// utterance. Built here from `context` (rather than threaded through from
    /// the transcriber) so the log always reflects what was actually sent,
    /// even for calls that construct an entry directly from a context.
    let prompt: String?
    /// The `config.keyterms_prompt` word-boost list sent for this utterance —
    /// the request's other steering field, so the log accounts for both. Built
    /// through the same `KeytermsBoost.fitted` the request uses, so an
    /// over-long list is recorded as the terms that actually went out. Empty
    /// when none were sent, and `encode(to:)` then omits the key, matching how
    /// every absent field above is left out rather than written as `null`.
    let keyterms: [String]

    /// Spelled out because a hand-written `encode(to:)` means the compiler no
    /// longer derives this — the key names are the on-disk contract for anything
    /// grepping or decoding the corpus, so they're stated rather than left to a
    /// synthesis that no longer happens.
    enum CodingKeys: String, CodingKey {
      case transcript, ts, app, window, field, prior, selected, prompt, keyterms
    }

    /// Hand-written for one field only: `keyterms` is a plain array (the repo
    /// bans optional collections), so synthesis would write `"keyterms":[]` on
    /// every line of a corpus where nothing else absent is written at all. The
    /// optional fields keep exactly the `encodeIfPresent` behavior synthesis
    /// gave them. `DictationLogEntryTests` asserts every field, so a property
    /// added above and forgotten here fails there rather than quietly vanishing
    /// from the log.
    func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(transcript, forKey: .transcript)
      try container.encode(ts, forKey: .ts)
      try container.encodeIfPresent(app, forKey: .app)
      try container.encodeIfPresent(window, forKey: .window)
      try container.encodeIfPresent(field, forKey: .field)
      try container.encodeIfPresent(prior, forKey: .prior)
      try container.encodeIfPresent(selected, forKey: .selected)
      try container.encodeIfPresent(prompt, forKey: .prompt)
      if !keyterms.isEmpty {
        try container.encode(keyterms, forKey: .keyterms)
      }
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
    gated(store: store) { now in
      write(transcript: transcript, context: context, to: url, now: now)
    }
  }

  /// The developer-mode gate plus the hop off the caller, shared by `append` and
  /// `appendError` (`DictationLog+Errors.swift`). Both halves of the log need the
  /// same two properties — the privacy switch and never blocking the
  /// `DictationSession` actor — so they're stated once here rather than at each
  /// entry point, for the reason `DictationSession.setPhase` hooks the error write
  /// centrally: a third log added later gets both by construction instead of by
  /// someone remembering.
  ///
  /// The timestamp is taken *before* the hop, so an entry is stamped when the
  /// dictation actually ended rather than whenever the serial queue reached it.
  ///
  /// Internal rather than `private` only because `appendError` lives in another
  /// file and Swift's `private` is file-scoped; nothing outside the two entry
  /// points should call it.
  static func gated(store: DeveloperModeStore, _ write: @escaping @Sendable (Date) -> Void) {
    guard store.isEnabled else { return }
    let now = Date()
    queue.async { write(now) }
  }

  /// One log entry as a value: which parts of the context are carried, how the
  /// timestamp is formatted, and the two steering fields — prompt and keyterms —
  /// mirroring what the transcriber actually sends, because both are built here
  /// through the same builders the request uses. Split from `write` so all of
  /// that is assertable directly rather than through a temp file and a substring
  /// search over the encoded line — a search that read the same whether a field
  /// was correctly absent or the write had failed outright.
  static func makeEntry(transcript: String, context: TranscriptionContext?, now: Date) -> Entry {
    Entry(
      transcript: transcript, ts: now.formatted(timestampFormat),
      app: context?.appName, window: context?.windowTitle, field: context?.fieldLabel,
      prior: context?.priorText, selected: context?.selectedText,
      prompt: TranscriptionPrompt.build(context: context),
      keyterms: KeytermsBoost.fitted(context?.keyTerms ?? [])
    )
  }

  /// The unconditional writer: formats one entry and appends it. Distinct name
  /// rather than an `append` overload so the gated entry point above can't be
  /// bypassed by accidentally satisfying a different signature.
  static func write(
    transcript: String, context: TranscriptionContext? = nil, to url: URL, now: Date
  ) {
    appendLine(makeEntry(transcript: transcript, context: context, now: now), to: url)
  }

  /// Encodes one entry and appends it as a JSONL line, creating the file (and
  /// `~/Library/Logs/Blurt`) on first write. Shared by the transcript log above
  /// and the error log (`DictationLog+Errors.swift`) so the two can't disagree
  /// about encoding, line termination, or lazy file creation.
  ///
  /// Never throws onto the dictation path: a diagnostic aid must not be able to
  /// break dictation. But it doesn't swallow the failure either — the write is
  /// the one error in the app that can't be reported through the error log
  /// (that's the thing that just failed), and an empty log with no explanation
  /// is indistinguishable from "nothing was ever dictated", so a failed append
  /// goes to `os_log`, the one channel that doesn't depend on this file.
  static func appendLine(_ entry: some Encodable, to url: URL) {
    do {
      var line = try makeEncoder().encode(entry)
      line.append(0x0A)  // '\n'
      try append(line: line, to: url)
    } catch {
      // Only the file name and the error, never the entry: the log's whole point
      // is that transcripts stay in an opt-in file, so they must not leak into a
      // system-wide log — and the absolute path carries the user's account name.
      let reason = error.localizedDescription
      logger.error(
        "append to \(url.lastPathComponent, privacy: .public) failed: \(reason, privacy: .public)")
    }
  }

  /// The throwing half of `appendLine`: open-or-create, seek, write. Split out so
  /// each step's error reaches the one `catch` above rather than being dropped by
  /// a `try?` per line, which is how a broken log used to go unnoticed.
  private static func append(line: Data, to url: URL) throws {
    let path = url.path(percentEncoded: false)
    if !FileManager.default.fileExists(atPath: path) {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      FileManager.default.createFile(atPath: path, contents: nil)
    }
    let handle = try FileHandle(forWritingTo: url)
    // `close` throws too, but the bytes are already written by then — reporting a
    // close failure as a lost entry would be a lie, so it stays a `try?`.
    defer { try? handle.close() }
    _ = try handle.seekToEnd()
    try handle.write(contentsOf: line)
  }

  private static let logger = Logger(
    subsystem: BlurtIdentity.subsystem, category: "DictationLog")
}

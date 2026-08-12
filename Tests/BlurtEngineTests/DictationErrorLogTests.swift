import Foundation
import Testing

@testable import BlurtEngine

private struct DecodedError: Decodable {
  let kind: String
  let error: String
  let ts: String
  let app: String?
  let window: String?
  let field: String?
}

/// Each test that genuinely needs a file gets a fresh empty one in a unique temp
/// directory so the host's real `~/Library/Logs/Blurt/errors.jsonl` is never
/// touched.
private func makeTempErrorLogURL() -> URL {
  let dir = FileManager.default.temporaryDirectory
    .appendingPathComponent("BlurtErrorLogTests-\(UUID().uuidString)", isDirectory: true)
  try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  return dir.appendingPathComponent("errors.jsonl")
}

private func readLog(_ url: URL) -> String {
  (try? String(contentsOf: url, encoding: .utf8)) ?? ""
}

private func firstEntry(in url: URL) -> DecodedError? {
  guard let line = readLog(url).split(separator: "\n").first.map(String.init) else { return nil }
  return try? JSONDecoder().decode(DecodedError.self, from: Data(line.utf8))
}

/// What one failure records. Driven through `makeErrorEntry`, because each of
/// these is a question about the entry rather than the file — including the one
/// that matters most: that the text the user was editing is nowhere in it. Asked
/// of a written line, that was `!line.contains("hunter2")` against a helper that
/// returns `""` on any read failure, so it also passed when nothing had been
/// written.
@Suite("DictationLog.makeErrorEntry")
struct DictationErrorEntryTests {
  private let context = TranscriptionContext(
    appName: "1Password", windowTitle: "Vault", fieldLabel: "Password",
    priorText: "hunter2", selectedText: "s3cret")

  @Test("records the stable kind, the human description, and a timestamp")
  func kindDescriptionAndTimestamp() {
    let entry = DictationLog.makeErrorEntry(
      .apiKeyMissing, context: nil, now: Date(timeIntervalSince1970: 1_700_000_000))
    #expect(entry.kind == "apiKeyMissing")
    #expect(entry.error == BlurtError.apiKeyMissing.errorDescription)
    #expect(entry.ts.hasPrefix("2023-11-14"))
  }

  /// The reason `error` is recorded in full and not just `kind`: for a
  /// transcription failure the underlying error carries the API status code and
  /// server message, which is the whole diagnosis.
  @Test("keeps the wrapped error's description for .sttFailed")
  func keepsUnderlyingDescription() {
    let underlying = NSError(
      domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "AssemblyAI error 429"])
    let entry = DictationLog.makeErrorEntry(
      .sttFailed(underlying: underlying), context: nil, now: Date())
    #expect(entry.kind == "sttFailed")
    #expect(entry.error.contains("AssemblyAI error 429"))
  }

  @Test("threads the focus context's app, window, and field")
  func threadsDiagnosticContext() {
    let entry = DictationLog.makeErrorEntry(.targetAppLost, context: context, now: Date())
    #expect(entry.app == "1Password")
    #expect(entry.window == "Vault")
    #expect(entry.field == "Password")
  }

  /// The error log is diagnostics-only: the text the user was editing explains
  /// nothing about a failure and is the most sensitive part of the snapshot, so
  /// the entry has no field to put it in. Reflecting over the encoded keys says
  /// so positively — a `prior` field added later fails this rather than silently
  /// starting to log passwords.
  @Test("has no field for prior text, selected text, or the assembled prompt")
  func carriesNoSurroundingText() throws {
    let entry = DictationLog.makeErrorEntry(.targetAppLost, context: context, now: Date())
    let data = try DictationLog.makeEncoder().encode(entry)
    let object = try JSONSerialization.jsonObject(with: data)
    let encoded = try #require(object as? [String: Any])
    #expect(encoded.keys.sorted() == ["app", "error", "field", "kind", "ts", "window"])
  }

  @Test("leaves the context fields nil when nothing was captured")
  func noContextLeavesFieldsNil() {
    let entry = DictationLog.makeErrorEntry(.apiKeyMissing, context: nil, now: Date())
    #expect(entry.app == nil)
    #expect(entry.window == nil)
    #expect(entry.field == nil)
  }
}

/// The on-disk format: what only a real file can answer.
@Suite("DictationLog.writeError")
struct DictationErrorLogTests {
  @Test("creates the file on first append")
  func createsFileOnFirstAppend() {
    let url = makeTempErrorLogURL()
    #expect(!FileManager.default.fileExists(atPath: url.path))
    DictationLog.writeError(.targetAppLost, to: url, now: Date())
    #expect(FileManager.default.fileExists(atPath: url.path))
  }

  @Test("writes one JSON object per line, terminated by \\n")
  func writesOneJSONLine() throws {
    let url = makeTempErrorLogURL()
    DictationLog.writeError(.apiKeyMissing, to: url, now: Date())
    let contents = readLog(url)
    #expect(contents.hasSuffix("\n"))
    // One data line + one trailing empty (from the \n).
    #expect(contents.split(separator: "\n", omittingEmptySubsequences: false).count == 2)
    let entry = try #require(firstEntry(in: url))
    #expect(entry.kind == "apiKeyMissing")
  }

  @Test("appends in order, preserves existing entries")
  func appendsInOrder() {
    let url = makeTempErrorLogURL()
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    DictationLog.writeError(.apiKeyMissing, to: url, now: t0)
    DictationLog.writeError(.targetAppLost, to: url, now: t0.addingTimeInterval(1))
    DictationLog.writeError(.noEditableTarget, to: url, now: t0.addingTimeInterval(2))
    let decoded = readLog(url)
      .split(separator: "\n", omittingEmptySubsequences: true)
      .compactMap { try? JSONDecoder().decode(DecodedError.self, from: Data($0.utf8)) }
    #expect(decoded.map(\.kind) == ["apiKeyMissing", "targetAppLost", "noEditableTarget"])
  }

  @Test("a nil entry field is omitted from the line, not written as null")
  func nilFieldsAreOmitted() throws {
    let url = makeTempErrorLogURL()
    DictationLog.writeError(.apiKeyMissing, context: nil, to: url, now: Date())
    // Require the entry landed first, so the missing keys below mean something.
    let entry = try #require(firstEntry(in: url))
    #expect(entry.kind == "apiKeyMissing")
    let line = readLog(url)
    #expect(!line.contains("\"app\""))
    #expect(!line.contains("\"window\""))
    #expect(!line.contains("\"field\""))
  }

  /// The log is a diagnostic aid, so it must never be able to break dictation: an
  /// undirectory-able destination reports through `os_log` and returns, rather than
  /// throwing back onto the pipeline. (`/dev/null` is a file, so creating a
  /// directory beneath it fails.)
  @Test("a destination that can't be created is a no-op, not a throw")
  func unwritableDestinationIsSurvivable() {
    let url = URL(fileURLWithPath: "/dev/null/nope/errors.jsonl")
    DictationLog.writeError(.targetAppLost, to: url, now: Date())
    #expect(!FileManager.default.fileExists(atPath: url.path))
  }
}

/// The developer-mode gate on `appendError` — the same privacy guarantee the
/// transcript log's gate carries: a user who never opts in has nothing on disk.
/// Every case in the suites above drives `makeErrorEntry`/`writeError` directly,
/// so none of them cross this guard.
@Suite("DictationLog error-log developer-mode gate")
struct DictationErrorLogGateTests {
  @Test("with developer mode off, appendError writes nothing to disk")
  func gateClosedWritesNothing() {
    let url = makeTempErrorLogURL()
    // An unset key reads as off, which is the default a user who never opts in has.
    let store = DeveloperModeStore(defaults: freshDefaults())
    let context = TranscriptionContext(
      appName: "1Password", windowTitle: "Vault", fieldLabel: "Password",
      priorText: "hunter2", selectedText: nil)
    DictationLog.appendError(.targetAppLost, context: context, store: store, to: url)
    // A dispatched write would have landed by the time this drains the serial queue,
    // so a missing file means nothing was ever enqueued — not that we looked early.
    DictationLog.queue.sync {}
    #expect(!FileManager.default.fileExists(atPath: url.path))
  }

  @Test("with developer mode on, appendError writes the failure")
  func gateOpenWrites() {
    let url = makeTempErrorLogURL()
    let store = developerModeStore(enabled: true)
    DictationLog.appendError(.targetAppLost, store: store, to: url)
    DictationLog.queue.sync {}
    #expect(readLog(url).contains("targetAppLost"))
  }

  /// One switch, both logs — the Developer section shows a single toggle, so
  /// neither half may read a different default.
  @Test("both logs answer to the same switch")
  func sharesTheDeveloperModeSwitch() {
    let defaults = freshDefaults()
    let store = developerModeStore(enabled: true, defaults: defaults)
    let errorURL = makeTempErrorLogURL()
    let transcriptURL = makeTempErrorLogURL()
    DictationLog.appendError(.targetAppLost, store: store, to: errorURL)
    DictationLog.append(transcript: "logged", store: store, to: transcriptURL)
    DictationLog.queue.sync {}
    #expect(!readLog(errorURL).isEmpty)
    #expect(!readLog(transcriptURL).isEmpty)

    // Flip the slot the Settings toggle owns. The store reads through to `defaults`
    // on every access, so this same instance now gates both logs off.
    defaults.set(false, forKey: DeveloperModeStore.defaultsKey)
    let offErrorURL = makeTempErrorLogURL()
    let offTranscriptURL = makeTempErrorLogURL()
    DictationLog.appendError(.targetAppLost, store: store, to: offErrorURL)
    DictationLog.append(transcript: "private", store: store, to: offTranscriptURL)
    DictationLog.queue.sync {}
    #expect(!FileManager.default.fileExists(atPath: offErrorURL.path))
    #expect(!FileManager.default.fileExists(atPath: offTranscriptURL.path))
  }

  /// The two logs are separate files: an error row must never land in the
  /// prompt-iteration corpus, whose readers expect every line to carry a
  /// `transcript`.
  @Test("the error log is a sibling file, not the dictations log")
  func writesToASiblingFile() {
    #expect(DictationLog.defaultErrorURL != DictationLog.defaultURL)
    #expect(
      DictationLog.defaultErrorURL.deletingLastPathComponent()
        == DictationLog.defaultURL.deletingLastPathComponent())
    #expect(DictationLog.defaultErrorURL.lastPathComponent == "errors.jsonl")
  }
}

/// The displayed error-log location, shown in the Settings window's Developer
/// section beside the switch that enables writing — so it has to name the file the
/// writer actually appends to.
@Suite("DictationLog.defaultErrorDisplayPath")
struct DictationErrorLogDisplayPathTests {
  @Test("abbreviates the home directory with a tilde")
  func abbreviatesHome() {
    let shown = DictationLog.defaultErrorDisplayPath
    #expect(shown.hasPrefix("~/"))
    // No absolute home path leaking into the UI (the label is selectable, and a
    // user's account name isn't wanted in a screenshot).
    #expect(!shown.contains(NSHomeDirectory()))
  }

  @Test("names the same file the writer appends to")
  func matchesTheWriteTarget() {
    #expect(DictationLog.defaultErrorDisplayPath.hasSuffix("Library/Logs/Blurt/errors.jsonl"))
    #expect(
      (DictationLog.defaultErrorDisplayPath as NSString).expandingTildeInPath
        == DictationLog.defaultErrorURL.path(percentEncoded: false))
  }
}

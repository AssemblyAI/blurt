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

/// Each test gets a fresh empty file in a unique temp directory so the host's real
/// `~/Library/Logs/Blurt/errors.jsonl` is never touched.
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

/// The unconditional writer: entry formatting and the on-disk JSONL shape. Whether
/// any of it runs is the developer-mode gate, covered in the suite below.
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
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    DictationLog.writeError(.apiKeyMissing, to: url, now: now)
    let contents = readLog(url)
    #expect(contents.hasSuffix("\n"))
    // One data line + one trailing empty (from the \n).
    #expect(contents.split(separator: "\n", omittingEmptySubsequences: false).count == 2)
    let decoded = try #require(firstEntry(in: url))
    #expect(decoded.kind == "apiKeyMissing")
    #expect(decoded.ts.contains("2023-11-14"))
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

  @Test("records the human-facing description alongside the stable kind")
  func recordsDescription() throws {
    let url = makeTempErrorLogURL()
    DictationLog.writeError(.apiKeyMissing, to: url, now: Date())
    let decoded = try #require(firstEntry(in: url))
    #expect(decoded.error == BlurtError.apiKeyMissing.errorDescription)
  }

  /// The reason `error` is logged in full and not just `kind`: for a transcription
  /// failure the underlying error carries the API status code and server message,
  /// which is the whole diagnosis.
  @Test("keeps the wrapped error's description for .sttFailed")
  func keepsUnderlyingDescription() throws {
    let url = makeTempErrorLogURL()
    let underlying = NSError(
      domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "AssemblyAI error 429"])
    DictationLog.writeError(.sttFailed(underlying: underlying), to: url, now: Date())
    let decoded = try #require(firstEntry(in: url))
    #expect(decoded.kind == "sttFailed")
    #expect(decoded.error.contains("AssemblyAI error 429"))
  }

  @Test("threads the focus context's app, window, and field onto disk")
  func logsContext() throws {
    let url = makeTempErrorLogURL()
    let context = TranscriptionContext(
      appName: "Mail", windowTitle: "Re: Q3 pricing", fieldLabel: "Body",
      priorText: "Hi Sam,", selectedText: "the old plan")
    DictationLog.writeError(.targetAppLost, context: context, to: url, now: Date())
    let decoded = try #require(firstEntry(in: url))
    #expect(decoded.app == "Mail")
    #expect(decoded.window == "Re: Q3 pricing")
    #expect(decoded.field == "Body")
  }

  /// The error log is diagnostics-only: the text the user was editing explains
  /// nothing about a failure and is the most sensitive part of the snapshot, so it
  /// must not be written even with developer mode on.
  @Test("never writes prior text, selected text, or the assembled prompt")
  func omitsSurroundingText() {
    let url = makeTempErrorLogURL()
    let context = TranscriptionContext(
      appName: "1Password", windowTitle: "Vault", fieldLabel: "Password",
      priorText: "hunter2", selectedText: "s3cret")
    DictationLog.writeError(.targetAppLost, context: context, to: url, now: Date())
    let line = readLog(url)
    #expect(!line.contains("hunter2"))
    #expect(!line.contains("s3cret"))
    #expect(!line.contains("\"prompt\""))
  }

  @Test("omits the context fields when nothing was captured")
  func omitsContextWhenAbsent() {
    let url = makeTempErrorLogURL()
    DictationLog.writeError(.apiKeyMissing, context: nil, to: url, now: Date())
    let line = readLog(url)
    // `Encodable` synthesis uses `encodeIfPresent`, so a nil field is absent
    // rather than `"app":null`.
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

  @Test("uses sorted JSON keys for deterministic on-disk format")
  func sortedKeys() throws {
    let url = makeTempErrorLogURL()
    DictationLog.writeError(.apiKeyMissing, to: url, now: Date())
    let line = readLog(url).split(separator: "\n").first.map(String.init) ?? ""
    // Sorted keys → error < kind < ts alphabetically.
    let error = try #require(line.range(of: "\"error\"")).lowerBound
    let kind = try #require(line.range(of: "\"kind\"")).lowerBound
    let ts = try #require(line.range(of: "\"ts\"")).lowerBound
    #expect(error < kind)
    #expect(kind < ts)
  }
}

/// The developer-mode gate on `appendError` — the same privacy guarantee the
/// transcript log's gate carries: a user who never opts in has nothing on disk.
/// Every case in the suite above drives `writeError` directly, so none of them
/// cross this guard.
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
    let store = DeveloperModeStore(defaults: freshDefaults())
    store.isEnabled = true
    DictationLog.appendError(.targetAppLost, store: store, to: url)
    DictationLog.queue.sync {}
    #expect(readLog(url).contains("targetAppLost"))
  }

  /// One switch, both logs — the Developer section shows a single toggle, so
  /// neither half may read a different default.
  @Test("both logs answer to the same switch")
  func sharesTheDeveloperModeSwitch() {
    let defaults = freshDefaults()
    let store = DeveloperModeStore(defaults: defaults)
    store.isEnabled = true
    let errorURL = makeTempErrorLogURL()
    let transcriptURL = makeTempErrorLogURL()
    DictationLog.appendError(.targetAppLost, store: store, to: errorURL)
    DictationLog.append(transcript: "logged", store: store, to: transcriptURL)
    DictationLog.queue.sync {}
    #expect(!readLog(errorURL).isEmpty)
    #expect(!readLog(transcriptURL).isEmpty)

    store.isEnabled = false
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

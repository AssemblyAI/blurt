import Foundation
import Testing

@testable import BlurtEngine

private struct DecodedEntry: Decodable {
  let transcript: String
  let ts: String
}

/// Each test that genuinely needs a file gets a fresh empty one in a unique temp
/// directory so the host's real `~/Library/Logs/Blurt/dictations.jsonl` is never
/// touched. File-scoped so the gate suite below shares it.
private func makeTempLogURL() -> URL {
  let dir = FileManager.default.temporaryDirectory
    .appendingPathComponent("BlurtDictationLogTests-\(UUID().uuidString)", isDirectory: true)
  try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  return dir.appendingPathComponent("dictations.jsonl")
}

private func readLog(_ url: URL) -> String {
  (try? String(contentsOf: url, encoding: .utf8)) ?? ""
}

/// The first written line decoded back, so a test can require the entry actually
/// landed before asserting anything about what the line does *not* contain.
private func firstEntry(in url: URL) -> DecodedEntry? {
  guard let line = readLog(url).split(separator: "\n").first.map(String.init) else { return nil }
  return try? JSONDecoder().decode(DecodedEntry.self, from: Data(line.utf8))
}

/// What one entry carries. These drive `makeEntry` and assert the value, because
/// every one of them is a question about the entry rather than about the file:
/// asked through `write` they needed a temp directory each, and the negative
/// cases ("no `selected` key", "no `prompt` key") were substring searches that
/// passed just as happily when nothing had been written.
@Suite("DictationLog.makeEntry")
struct DictationLogEntryTests {
  private let context = TranscriptionContext(
    appName: "Mail", windowTitle: "Re: Q3 pricing", fieldLabel: "Body",
    priorText: "Hi Sam,", selectedText: "the old plan")

  @Test("carries the transcript and an ISO-8601 timestamp")
  func transcriptAndTimestamp() {
    let entry = DictationLog.makeEntry(
      transcript: "Polished.", context: nil, now: Date(timeIntervalSince1970: 1_700_000_000))
    #expect(entry.transcript == "Polished.")
    #expect(entry.ts.hasPrefix("2023-11-14"))
  }

  @Test("threads every focus-context field, including the selected text")
  func threadsContext() {
    let entry = DictationLog.makeEntry(transcript: "p", context: context, now: Date())
    #expect(entry.app == "Mail")
    #expect(entry.window == "Re: Q3 pricing")
    #expect(entry.field == "Body")
    #expect(entry.prior == "Hi Sam,")
    #expect(entry.selected == "the old plan")
  }

  @Test("leaves every context field nil when nothing was captured")
  func noContextLeavesFieldsNil() {
    let entry = DictationLog.makeEntry(transcript: "p", context: nil, now: Date())
    #expect(entry.app == nil)
    #expect(entry.window == nil)
    #expect(entry.field == nil)
    #expect(entry.prior == nil)
    #expect(entry.selected == nil)
    #expect(entry.prompt == nil)
    #expect(entry.keyterms.isEmpty)
  }

  @Test("logs the same prompt the transcriber sends — the prior chunk and nothing else")
  func logsWhatTheRequestCarries() {
    let entry = DictationLog.makeEntry(transcript: "p", context: context, now: Date())
    // The entry mirrors the request because the writer calls the same builder.
    #expect(entry.prompt == TranscriptionPrompt.build(context: context))
    // So the logged prompt shows the narrowing too: the prior chunk went on the
    // wire, the window title and the selected text did not — even though the
    // entry's own fields record all three.
    #expect(entry.prompt?.contains("Hi Sam,") == true)
    #expect(entry.prompt?.contains("Re: Q3 pricing") == false)
    #expect(entry.prompt?.contains("the old plan") == false)
  }

  @Test("records the key terms the request boosts, fitted the same way")
  func logsTheKeytermsTheRequestCarries() {
    // Through `KeytermsBoost.fitted`, not the raw list: the log has to show the
    // steering the API actually saw, so a blank entry is dropped here too.
    let withTerms = TranscriptionContext(
      appName: "Mail", priorText: "Hi Sam,", keyTerms: ["AssemblyAI", "  ", "LeMUR"])
    let entry = DictationLog.makeEntry(transcript: "p", context: withTerms, now: Date())
    #expect(entry.keyterms == ["AssemblyAI", "LeMUR"])
  }

  @Test("leaves the key terms empty when the context has none")
  func noKeytermsLeavesTheFieldEmpty() {
    #expect(DictationLog.makeEntry(transcript: "p", context: context, now: Date()).keyterms.isEmpty)
  }

  @Test("keeps a transcript verbatim, including non-ASCII")
  func unicodeKeptVerbatim() {
    let transcript = "Café — 北京 🎙️."
    #expect(DictationLog.makeEntry(transcript: transcript, context: nil, now: Date()).transcript == transcript)
  }
}

/// The on-disk format itself: what only a real file can answer — lazy creation,
/// one-object-per-line framing, append order, and that a nil field is omitted
/// rather than serialized as `null`.
@Suite("DictationLog.write")
struct DictationLogTests {
  @Test("creates the file on first append")
  func createsFileOnFirstAppend() {
    let url = makeTempLogURL()
    #expect(!FileManager.default.fileExists(atPath: url.path))
    DictationLog.write(transcript: "Hi.", to: url, now: Date())
    #expect(FileManager.default.fileExists(atPath: url.path))
  }

  @Test("writes one JSON object per line, terminated by \\n")
  func writesOneJSONLine() throws {
    let url = makeTempLogURL()
    DictationLog.write(
      transcript: "Polished.", to: url, now: Date(timeIntervalSince1970: 1_700_000_000))
    let contents = readLog(url)
    #expect(contents.hasSuffix("\n"))
    // One data line + one trailing empty (from the \n).
    #expect(contents.split(separator: "\n", omittingEmptySubsequences: false).count == 2)
    let decoded = try #require(firstEntry(in: url))
    #expect(decoded.transcript == "Polished.")
    #expect(decoded.ts.contains("2023-11-14"))
  }

  @Test("appends in order, preserves existing entries")
  func appendsInOrder() {
    let url = makeTempLogURL()
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    DictationLog.write(transcript: "A.", to: url, now: t0)
    DictationLog.write(transcript: "B.", to: url, now: t0.addingTimeInterval(1))
    DictationLog.write(transcript: "C.", to: url, now: t0.addingTimeInterval(2))
    let decoded = readLog(url)
      .split(separator: "\n", omittingEmptySubsequences: true)
      .compactMap { try? JSONDecoder().decode(DecodedEntry.self, from: Data($0.utf8)) }
    #expect(decoded.map(\.transcript) == ["A.", "B.", "C."])
  }

  @Test("a nil entry field is omitted from the line, not written as null")
  func nilFieldsAreOmitted() throws {
    let url = makeTempLogURL()
    DictationLog.write(transcript: "p", context: nil, to: url, now: Date())
    // Non-vacuous: the line has to exist and carry the transcript before its
    // *missing* keys mean anything.
    let entry = try #require(firstEntry(in: url))
    #expect(entry.transcript == "p")
    // `Entry.encode(to:)` uses `encodeIfPresent`, so a nil field is absent rather
    // than `"selected":null` — and it skips an empty `keyterms` for the same
    // reason, since a plain array would otherwise encode as `[]` on every line.
    let line = readLog(url)
    #expect(!line.contains("selected"))
    #expect(!line.contains("\"prompt\""))
    #expect(!line.contains("keyterms"))
  }
}

/// The shared encoder both logs write through.
@Suite("DictationLog.makeEncoder")
struct DictationLogEncoderTests {
  @Test("sorts keys, so the on-disk JSONL is byte-stable")
  func sortsKeys() {
    // Asserted on the encoder rather than by comparing where key names happen to
    // land in a written line: a stable diff for post-hoc greps is a property of
    // this configuration, and both logs share it.
    #expect(DictationLog.makeEncoder().outputFormatting.contains(.sortedKeys))
  }
}

/// The developer-mode gate on `append` — the switch's entire privacy guarantee:
/// "a user who never opts in has no dictation text on disk." Every case in the
/// suites above drives `makeEntry`/`write` directly, so none of them cross this
/// guard.
@Suite("DictationLog developer-mode gate")
struct DictationLogGateTests {
  @Test("with developer mode off, append writes nothing to disk")
  func gateClosedWritesNothing() {
    let url = makeTempLogURL()
    // An unset key reads as off, which is the default a user who never opts in has.
    let store = DeveloperModeStore(defaults: freshDefaults())
    DictationLog.append(transcript: "private dictation", store: store, to: url)
    // A dispatched write would have landed by the time this drains the serial queue,
    // so a missing file means nothing was ever enqueued — not that we looked early.
    DictationLog.queue.sync {}
    #expect(!FileManager.default.fileExists(atPath: url.path))
  }

  @Test("with developer mode on, append writes the transcript")
  func gateOpenWrites() {
    let url = makeTempLogURL()
    let store = developerModeStore(enabled: true)
    DictationLog.append(transcript: "logged dictation", store: store, to: url)
    DictationLog.queue.sync {}
    #expect(readLog(url).contains("logged dictation"))
  }

  @Test("the gate is checked before the context is touched, for both settings")
  func gateAppliesToContextualEntries() {
    // The pipeline always passes the captured context, which is the part carrying
    // prior text and the assembled prompt. Off must persist none of it.
    let context = TranscriptionContext(
      appName: "1Password", windowTitle: "Vault", fieldLabel: "Password",
      priorText: "hunter2", selectedText: nil)
    let offURL = makeTempLogURL()
    DictationLog.append(
      transcript: "p", context: context,
      store: DeveloperModeStore(defaults: freshDefaults()), to: offURL)

    let onStore = developerModeStore(enabled: true)
    let onURL = makeTempLogURL()
    DictationLog.append(transcript: "p", context: context, store: onStore, to: onURL)

    DictationLog.queue.sync {}
    #expect(!FileManager.default.fileExists(atPath: offURL.path))
    #expect(readLog(onURL).contains("hunter2"))
  }
}

/// The displayed log location. The Settings window's Developer section shows this
/// beside the switch that enables writing, so it has to name the file the writer
/// actually appends to — the reason the formatting moved out of the view.
@Suite("DictationLog.defaultDisplayPath")
struct DictationLogDisplayPathTests {
  @Test("abbreviates the home directory with a tilde")
  func abbreviatesHome() {
    let shown = DictationLog.defaultDisplayPath
    #expect(shown.hasPrefix("~/"))
    // No absolute home path leaking into the UI (the label is selectable, and a
    // user's account name isn't wanted in a screenshot).
    #expect(!shown.contains(NSHomeDirectory()))
  }

  @Test("names the same file the writer appends to")
  func matchesTheWriteTarget() {
    // The whole point of deriving this next to `defaultURL`: the two can't drift.
    #expect(DictationLog.defaultDisplayPath.hasSuffix("Library/Logs/Blurt/dictations.jsonl"))
    #expect(
      (DictationLog.defaultDisplayPath as NSString).expandingTildeInPath
        == DictationLog.defaultURL.path(percentEncoded: false))
  }
}

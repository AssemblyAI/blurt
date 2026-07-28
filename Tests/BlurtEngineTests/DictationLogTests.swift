import Foundation
import Testing

@testable import BlurtEngine

private struct DecodedEntry: Decodable {
  let transcript: String
  let ts: String
}

/// Decodes the optional focus-context fields so tests can assert they're
/// threaded from the `TranscriptionContext` onto disk.
private struct DecodedContext: Decodable {
  let app: String?
  let bundle: String?
  let window: String?
  let field: String?
  let prior: String?
  let selected: String?
  let prompt: String?
}

/// Each test gets a fresh empty file in a unique temp directory so the host's real
/// `~/Library/Logs/Blurt/dictations.jsonl` is never touched. File-scoped so the
/// gate suite below shares it.
private func makeTempLogURL() -> URL {
  let dir = FileManager.default.temporaryDirectory
    .appendingPathComponent("BlurtDictationLogTests-\(UUID().uuidString)", isDirectory: true)
  try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  return dir.appendingPathComponent("dictations.jsonl")
}

private func readLog(_ url: URL) -> String {
  (try? String(contentsOf: url, encoding: .utf8)) ?? ""
}

/// The unconditional writer: entry formatting and the on-disk JSONL shape. Whether
/// any of it runs at all is the developer-mode gate, covered in the suite below.
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
  func writesOneJSONLine() {
    let url = makeTempLogURL()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    DictationLog.write(transcript: "Polished.", to: url, now: now)
    let contents = readLog(url)
    #expect(contents.hasSuffix("\n"))
    let lines = contents.split(separator: "\n", omittingEmptySubsequences: false)
    // One data line + one trailing empty (from the \n).
    #expect(lines.count == 2)
    let decoded = try? JSONDecoder().decode(
      DecodedEntry.self,
      from: Data(lines[0].utf8))
    #expect(decoded?.transcript == "Polished.")
    #expect(decoded?.ts.contains("2023-11-14") == true)
  }

  @Test("appends in order, preserves existing entries")
  func appendsInOrder() {
    let url = makeTempLogURL()
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    let t1 = t0.addingTimeInterval(1)
    let t2 = t1.addingTimeInterval(1)
    DictationLog.write(transcript: "A.", to: url, now: t0)
    DictationLog.write(transcript: "B.", to: url, now: t1)
    DictationLog.write(transcript: "C.", to: url, now: t2)
    let lines = readLog(url)
      .split(separator: "\n", omittingEmptySubsequences: true)
      .map(String.init)
    #expect(lines.count == 3)
    let decoded = lines.compactMap { line -> DecodedEntry? in
      try? JSONDecoder().decode(DecodedEntry.self, from: Data(line.utf8))
    }
    #expect(decoded.map(\.transcript) == ["A.", "B.", "C."])
  }

  @Test("uses sorted JSON keys for deterministic on-disk format")
  func sortedKeys() throws {
    let url = makeTempLogURL()
    DictationLog.write(transcript: "p", to: url, now: Date())
    let line = readLog(url).split(separator: "\n").first.map(String.init) ?? ""
    // Sorted keys → transcript < ts alphabetically.
    let transcript = try #require(line.range(of: "\"transcript\"")).lowerBound
    let ts = try #require(line.range(of: "\"ts\"")).lowerBound
    #expect(transcript < ts)
  }

  @Test("threads focus context (incl. selected text) onto disk")
  func logsContext() {
    let url = makeTempLogURL()
    let context = TranscriptionContext(
      appName: "Mail", bundleID: "com.apple.mail", windowTitle: "Re: Q3 pricing",
      fieldLabel: "Body", priorText: "Hi Sam,", selectedText: "the old plan")
    DictationLog.write(transcript: "p", context: context, to: url, now: Date())
    let line = readLog(url).split(separator: "\n").first.map(String.init) ?? ""
    let decoded = try? JSONDecoder().decode(DecodedContext.self, from: Data(line.utf8))
    #expect(decoded?.app == "Mail")
    #expect(decoded?.bundle == "com.apple.mail")
    #expect(decoded?.window == "Re: Q3 pricing")
    #expect(decoded?.field == "Body")
    #expect(decoded?.prior == "Hi Sam,")
    #expect(decoded?.selected == "the old plan")
  }

  @Test("omits the selected field when nothing is selected")
  func omitsSelectedWhenAbsent() {
    let url = makeTempLogURL()
    DictationLog.write(transcript: "p", context: nil, to: url, now: Date())
    let line = readLog(url).split(separator: "\n").first.map(String.init) ?? ""
    // `Encodable` synthesis uses `encodeIfPresent`, so a nil field is absent
    // rather than `"selected":null`.
    #expect(!line.contains("selected"))
  }

  @Test("logs the same assembled prompt the transcriber sends")
  func logsAssembledPrompt() {
    let url = makeTempLogURL()
    let context = TranscriptionContext(
      appName: "Mail", windowTitle: "Re: Q3 pricing", fieldLabel: "Body",
      priorText: "Hi Sam,", selectedText: "the old plan")
    DictationLog.write(transcript: "p", context: context, to: url, now: Date())
    let line = readLog(url).split(separator: "\n").first.map(String.init) ?? ""
    let decoded = try? JSONDecoder().decode(DecodedContext.self, from: Data(line.utf8))
    #expect(decoded?.prompt == TranscriptionPrompt.build(context: context))
  }

  @Test("the logged prompt carries the app-kind guidance the bundle ID selected")
  func logsPromptWithAppKindGuidance() {
    let url = makeTempLogURL()
    let context = TranscriptionContext(
      appName: "Slack", bundleID: "com.tinyspeck.slackmacgap", fieldLabel: "Message",
      priorText: nil)
    DictationLog.write(transcript: "p", context: context, to: url, now: Date())
    let line = readLog(url).split(separator: "\n").first.map(String.init) ?? ""
    let decoded = try? JSONDecoder().decode(DecodedContext.self, from: Data(line.utf8))
    // The exact wording is TranscriptionPromptTests' contract; here the point is
    // that what lands on disk includes the guidance actually sent for this app.
    #expect(decoded?.prompt?.contains("You are writing a Slack message") == true)
  }

  @Test("omits the prompt field when there is no context to build one")
  func omitsPromptWhenNoContext() {
    let url = makeTempLogURL()
    DictationLog.write(transcript: "p", context: nil, to: url, now: Date())
    let line = readLog(url).split(separator: "\n").first.map(String.init) ?? ""
    #expect(!line.contains("\"prompt\""))
  }

  @Test("survives unicode in transcript field")
  func unicodeRoundTrip() {
    let url = makeTempLogURL()
    let transcript = "Café — 北京 🎙️."
    DictationLog.write(transcript: transcript, to: url, now: Date())
    let line = readLog(url).split(separator: "\n").first.map(String.init) ?? ""
    let decoded = try? JSONDecoder().decode(DecodedEntry.self, from: Data(line.utf8))
    #expect(decoded?.transcript == transcript)
  }
}

/// The developer-mode gate on `append` — the switch's entire privacy guarantee:
/// "a user who never opts in has no dictation text on disk." Every case in the
/// suite above drives `write` directly, so none of them cross this guard.
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
    let store = DeveloperModeStore(defaults: freshDefaults())
    store.isEnabled = true
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

    let onStore = DeveloperModeStore(defaults: freshDefaults())
    onStore.isEnabled = true
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

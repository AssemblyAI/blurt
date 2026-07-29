import Foundation
import Testing

@testable import BlurtEngine

private struct DecodedEntry: Decodable {
  let transcript: String
  let ts: String
}

/// Decodes the steering fields so tests can assert the exact request
/// customization that was sent is what lands on disk, under the same wire names
/// the request uses.
private struct DecodedSteering: Decodable {
  let conversationContext: [String]
  let keytermsPrompt: [String]
  let llmInstruction: String?

  enum CodingKeys: String, CodingKey {
    case conversationContext = "conversation_context"
    case keytermsPrompt = "keyterms_prompt"
    case llmInstruction = "llm_instruction"
  }

  // A missing array decodes to empty rather than nil: whether a field was
  // *omitted* is asserted against the raw line, so nothing here needs to tell
  // absent from empty.
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    conversationContext = try container.decodeIfPresent([String].self, forKey: .conversationContext) ?? []
    keytermsPrompt = try container.decodeIfPresent([String].self, forKey: .keytermsPrompt) ?? []
    llmInstruction = try container.decodeIfPresent(String.self, forKey: .llmInstruction)
  }
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

  @Test("logs only what was sent — context captured but never sent stays off disk")
  func logsOnlyWhatWasSent() {
    let url = makeTempLogURL()
    let context = TranscriptionContext(
      appName: "Obsidian", bundleID: "md.obsidian", windowTitle: "Grocery list",
      fieldLabel: "text entry area", priorText: "- milk", selectedText: "- bread")
    DictationLog.write(transcript: "p", context: context, to: url, now: Date())
    let line = readLog(url).split(separator: "\n").first.map(String.init) ?? ""
    // Everything the request carried is recorded, under the wire's own names…
    let decoded = try? JSONDecoder().decode(DecodedSteering.self, from: Data(line.utf8))
    #expect(decoded?.llmInstruction == "Format the result as markdown.")
    #expect(decoded?.conversationContext == ["- milk"])
    // …and none of the captured-but-unsent context is. Values, not just keys:
    // the entry must carry no trace of what stayed on the machine. Selected text
    // is on this list because the paste replaces it, so it is never sent.
    for unsent in ["Obsidian", "md.obsidian", "Grocery list", "text entry area", "- bread"] {
      #expect(!line.contains(unsent))
    }
  }

  @Test("logs the same steering fields the transcriber sends")
  func logsAssembledSteering() {
    let url = makeTempLogURL()
    let context = TranscriptionContext(
      appName: "Obsidian", bundleID: "md.obsidian", windowTitle: "Grocery list",
      fieldLabel: "text entry area", priorText: "- milk", keyTerms: ["Blurt"])
    DictationLog.write(transcript: "p", context: context, to: url, now: Date())
    let line = readLog(url).split(separator: "\n").first.map(String.init) ?? ""
    let decoded = try? JSONDecoder().decode(DecodedSteering.self, from: Data(line.utf8))
    let sent = TranscriptionSteering.build(context: context)
    // The log is the corpus prompt iteration reads, so it has to agree with the
    // builder field-for-field rather than approximately.
    #expect(decoded?.llmInstruction == sent.rewriteInstruction)
    #expect(decoded?.conversationContext == sent.conversationContext)
    #expect(decoded?.keytermsPrompt == sent.keyterms)
    #expect(decoded?.llmInstruction == "Format the result as markdown.")
    #expect(decoded?.keytermsPrompt == ["Blurt"])
  }

  @Test("omits every steering field when there is no context to build one")
  func omitsSteeringWhenNoContext() {
    let url = makeTempLogURL()
    DictationLog.write(transcript: "p", context: nil, to: url, now: Date())
    let line = readLog(url).split(separator: "\n").first.map(String.init) ?? ""
    // Absent, not `null` and not `[]` — the entry should read as "nothing was
    // customized", matching the request, which omits these fields too.
    #expect(!line.contains("\"prompt\""))
    #expect(!line.contains("\"llm_instruction\""))
    #expect(!line.contains("\"conversation_context\""))
    #expect(!line.contains("\"keyterms_prompt\""))
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
    // The pipeline always passes the captured context — the input the logged
    // steering fields are built from. Off must persist nothing at all; on
    // persists what was sent, and still never the context that wasn't (the
    // window title and field label stay off disk either way).
    //
    // Prior-cursor text *is* sent now (as `conversation_context`), so it is on
    // disk for a user who opted in. What keeps a password out of it is upstream,
    // in `FocusCapture`: prior and selected text are skipped entirely in secure
    // fields, failing closed when the AX role can't be read. That guard is
    // covered in `FocusCaptureTests`; this suite can only see contexts that
    // already cleared it.
    let context = TranscriptionContext(
      appName: "Terminal", bundleID: "com.apple.Terminal",
      windowTitle: "Vault", fieldLabel: "Command",
      priorText: "$ git", selectedText: nil)
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
    let logged = readLog(onURL)
    #expect(logged.contains("Format the result as a shell command with no trailing period."))
    #expect(logged.contains("$ git"))
    #expect(!logged.contains("Vault"))
    #expect(!logged.contains("Command"))
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

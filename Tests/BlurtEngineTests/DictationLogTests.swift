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
  let window: String?
  let field: String?
  let prior: String?
  let selected: String?
  let prompt: String?
}

@Suite("DictationLog.append")
struct DictationLogTests {
  /// Each test gets a fresh empty file in a unique temp directory so the
  /// host's real `~/Library/Logs/Blurt/dictations.jsonl` is never touched.
  private func makeURL() -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("BlurtDictationLogTests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("dictations.jsonl")
  }

  private func read(_ url: URL) -> String {
    (try? String(contentsOf: url, encoding: .utf8)) ?? ""
  }

  @Test("creates the file on first append")
  func createsFileOnFirstAppend() {
    let url = makeURL()
    #expect(!FileManager.default.fileExists(atPath: url.path))
    DictationLog.append(transcript: "Hi.", to: url, now: Date())
    #expect(FileManager.default.fileExists(atPath: url.path))
  }

  @Test("writes one JSON object per line, terminated by \\n")
  func writesOneJSONLine() {
    let url = makeURL()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    DictationLog.append(transcript: "Polished.", to: url, now: now)
    let contents = read(url)
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
    let url = makeURL()
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    let t1 = t0.addingTimeInterval(1)
    let t2 = t1.addingTimeInterval(1)
    DictationLog.append(transcript: "A.", to: url, now: t0)
    DictationLog.append(transcript: "B.", to: url, now: t1)
    DictationLog.append(transcript: "C.", to: url, now: t2)
    let lines = read(url)
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
    let url = makeURL()
    DictationLog.append(transcript: "p", to: url, now: Date())
    let line = read(url).split(separator: "\n").first.map(String.init) ?? ""
    // Sorted keys → transcript < ts alphabetically.
    let transcript = try #require(line.range(of: "\"transcript\"")).lowerBound
    let ts = try #require(line.range(of: "\"ts\"")).lowerBound
    #expect(transcript < ts)
  }

  @Test("threads focus context (incl. selected text) onto disk")
  func logsContext() {
    let url = makeURL()
    let context = TranscriptionContext(
      appName: "Mail", windowTitle: "Re: Q3 pricing", fieldLabel: "Body",
      priorText: "Hi Sam,", selectedText: "the old plan")
    DictationLog.append(transcript: "p", context: context, to: url, now: Date())
    let line = read(url).split(separator: "\n").first.map(String.init) ?? ""
    let decoded = try? JSONDecoder().decode(DecodedContext.self, from: Data(line.utf8))
    #expect(decoded?.app == "Mail")
    #expect(decoded?.window == "Re: Q3 pricing")
    #expect(decoded?.field == "Body")
    #expect(decoded?.prior == "Hi Sam,")
    #expect(decoded?.selected == "the old plan")
  }

  @Test("omits the selected field when nothing is selected")
  func omitsSelectedWhenAbsent() {
    let url = makeURL()
    DictationLog.append(transcript: "p", context: nil, to: url, now: Date())
    let line = read(url).split(separator: "\n").first.map(String.init) ?? ""
    // `Encodable` synthesis uses `encodeIfPresent`, so a nil field is absent
    // rather than `"selected":null`.
    #expect(!line.contains("selected"))
  }

  @Test("logs the same assembled prompt the transcriber sends")
  func logsAssembledPrompt() {
    let url = makeURL()
    let context = TranscriptionContext(
      appName: "Mail", windowTitle: "Re: Q3 pricing", fieldLabel: "Body",
      priorText: "Hi Sam,", selectedText: "the old plan")
    DictationLog.append(transcript: "p", context: context, to: url, now: Date())
    let line = read(url).split(separator: "\n").first.map(String.init) ?? ""
    let decoded = try? JSONDecoder().decode(DecodedContext.self, from: Data(line.utf8))
    #expect(decoded?.prompt == TranscriptionPrompt.build(context: context))
  }

  @Test("omits the prompt field when there is no context to build one")
  func omitsPromptWhenNoContext() {
    let url = makeURL()
    DictationLog.append(transcript: "p", context: nil, to: url, now: Date())
    let line = read(url).split(separator: "\n").first.map(String.init) ?? ""
    #expect(!line.contains("\"prompt\""))
  }

  @Test("survives unicode in transcript field")
  func unicodeRoundTrip() {
    let url = makeURL()
    let transcript = "Café — 北京 🎙️."
    DictationLog.append(transcript: transcript, to: url, now: Date())
    let line = read(url).split(separator: "\n").first.map(String.init) ?? ""
    let decoded = try? JSONDecoder().decode(DecodedEntry.self, from: Data(line.utf8))
    #expect(decoded?.transcript == transcript)
  }
}

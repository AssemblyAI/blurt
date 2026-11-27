import Foundation
import Testing

@testable import AssemblyAI
@testable import BlurtEngine

/// Each test that genuinely needs a file gets a fresh empty one in a unique temp
/// directory, removed when `body` returns, so the host's real
/// `~/Library/Logs/Blurt/dictations.jsonl` is never touched. Internal so the
/// gate suites (`DictationLogGateTests`, `DictationLogRemovalTests`) share it,
/// along with `readLog`.
func withTempLogURL(_ body: (URL) throws -> Void) throws {
  try withTempLogFile("dictations.jsonl", body)
}

func readLog(_ url: URL) -> String {
  (try? String(contentsOf: url, encoding: .utf8)) ?? ""
}

/// The first written line decoded back, so a test can require the entry actually
/// landed before asserting anything about what the line does *not* contain.
private func firstEntry(in url: URL) -> DecodedEntry? {
  guard let line = readLog(url).split(separator: "\n").first.map(String.init) else {
    return nil
  }
  return try? JSONDecoder().decode(DecodedEntry.self, from: Data(line.utf8))
}

/// The on-disk format itself: what only a real file can answer — lazy creation,
/// one-object-per-line framing, append order, and that a nil field is omitted
/// rather than serialized as `null`.
@Suite("DictationLog.write")
struct DictationLogTests {
  @Test("creates the file on first append")
  func createsFileOnFirstAppend() throws {
    try withTempLogURL { url in
      #expect(!FileManager.default.fileExists(atPath: url.path))
      DictationLog.write(transcript: "Hi.", to: url, now: Date())
      #expect(FileManager.default.fileExists(atPath: url.path))
    }
  }

  @Test("writes one JSON object per line, terminated by \\n")
  func writesOneJSONLine() throws {
    try withTempLogURL { url in
      DictationLog.write(
        transcript: "Polished.", to: url, now: Date(timeIntervalSince1970: 1_700_000_000)
      )
      let contents = readLog(url)
      #expect(contents.hasSuffix("\n"))
      // One data line + one trailing empty (from the \n).
      #expect(contents.split(separator: "\n", omittingEmptySubsequences: false).count == 2)
      let decoded = try #require(firstEntry(in: url))
      #expect(decoded.transcript == "Polished.")
      #expect(decoded.ts.contains("2023-11-14"))
    }
  }

  @Test("appends in order, preserves existing entries")
  func appendsInOrder() throws {
    try withTempLogURL { url in
      let t0 = Date(timeIntervalSince1970: 1_700_000_000)
      DictationLog.write(transcript: "A.", to: url, now: t0)
      DictationLog.write(transcript: "B.", to: url, now: t0.addingTimeInterval(1))
      DictationLog.write(transcript: "C.", to: url, now: t0.addingTimeInterval(2))
      let decoded = readLog(url)
        .split(separator: "\n", omittingEmptySubsequences: true)
        .compactMap { try? JSONDecoder().decode(DecodedEntry.self, from: Data($0.utf8)) }
      #expect(decoded.map(\.transcript) == ["A.", "B.", "C."])
    }
  }

  @Test("a nil entry field is omitted from the line, not written as null")
  func nilFieldsAreOmitted() throws {
    try withTempLogURL { url in
      DictationLog.write(transcript: "p", to: url, now: Date(), context: nil)
      // Non-vacuous: the line has to exist and carry the transcript before its
      // *missing* keys mean anything.
      let entry = try #require(firstEntry(in: url))
      #expect(entry.transcript == "p")
      // `Entry.encode(to:)` uses `encodeIfPresent`, so a nil field is absent rather
      // than `"selected":null` — and it skips an empty `keyterms` for the same
      // reason, since a plain array would otherwise encode as `[]` on every line.
      let line = readLog(url)
      #expect(!line.contains("selected"))
      #expect(!line.contains("stt_prompt"))
      #expect(!line.contains("keyterms"))
      #expect(!line.contains("rewrite_mode"))
    }
  }

  @Test("a non-empty prompt/keyterms pair is written, with its values intact")
  func conditionalFieldsAreWrittenWhenPresent() throws {
    // The other direction of the same contract. `nilFieldsAreOmitted` pins the
    // conditional arms' *skip*; without this, `encode(to:)` could stop writing
    // either field entirely and only the negative test would still pass — leaving
    // the corpus with no record of what steering a request carried.
    try withTempLogURL { url in
      let context = TranscriptionContext(
        appName: "Mail", priorText: "Hi Sam,", keyTerms: ["AssemblyAI", "LeMUR"]
      )
      DictationLog.write(
        transcript: "p", to: url, now: Date(), context: context, contextPrompt: "Hi Sam,", rewriteMode: .smart
      )

      let entry = try #require(firstEntry(in: url))
      #expect(entry.keyterms == ["AssemblyAI", "LeMUR"])
      #expect(entry.sttPrompt == "Hi Sam,")
      #expect(readLog(url).contains(#""rewrite_mode":"smart""#))
    }
  }
}

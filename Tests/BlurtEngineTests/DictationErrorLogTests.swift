import Foundation
import Testing

@testable import BlurtEngine

/// Each test that genuinely needs a file gets a fresh empty one in a unique temp
/// directory, removed when `body` returns, so the host's real
/// `~/Library/Logs/Blurt/errors.jsonl` is never touched. Internal so
/// `DictationErrorLogGateTests` shares it.
func withTempErrorLogURL(_ body: (URL) throws -> Void) throws {
  try withTempLogFile("errors.jsonl", body)
}

private func firstEntry(in url: URL) -> DecodedError? {
  guard let line = readLog(url).split(separator: "\n").first.map(String.init) else {
    return nil
  }
  return try? JSONDecoder().decode(DecodedError.self, from: Data(line.utf8))
}

/// The on-disk format: what only a real file can answer.
@Suite("DictationLog.writeError")
struct DictationErrorLogTests {
  @Test("creates the file on first append")
  func createsFileOnFirstAppend() throws {
    try withTempErrorLogURL { url in
      #expect(!FileManager.default.fileExists(atPath: url.path))
      DictationLog.writeError(.targetAppLost, to: url, now: Date())
      #expect(FileManager.default.fileExists(atPath: url.path))
    }
  }

  @Test("writes one JSON object per line, terminated by \\n")
  func writesOneJSONLine() throws {
    try withTempErrorLogURL { url in
      DictationLog.writeError(.apiKeyMissing, to: url, now: Date())
      let contents = readLog(url)
      #expect(contents.hasSuffix("\n"))
      // One data line + one trailing empty (from the \n).
      #expect(contents.split(separator: "\n", omittingEmptySubsequences: false).count == 2)
      let entry = try #require(firstEntry(in: url))
      #expect(entry.kind == "apiKeyMissing")
    }
  }

  @Test("appends in order, preserves existing entries")
  func appendsInOrder() throws {
    try withTempErrorLogURL { url in
      let t0 = Date(timeIntervalSince1970: 1_700_000_000)
      DictationLog.writeError(.apiKeyMissing, to: url, now: t0)
      DictationLog.writeError(.targetAppLost, to: url, now: t0.addingTimeInterval(1))
      DictationLog.writeError(.noEditableTarget, to: url, now: t0.addingTimeInterval(2))
      let decoded = readLog(url)
        .split(separator: "\n", omittingEmptySubsequences: true)
        .compactMap { try? JSONDecoder().decode(DecodedError.self, from: Data($0.utf8)) }
      #expect(decoded.map(\.kind) == ["apiKeyMissing", "targetAppLost", "noEditableTarget"])
    }
  }

  @Test("a nil entry field is omitted from the line, not written as null")
  func nilFieldsAreOmitted() throws {
    try withTempErrorLogURL { url in
      DictationLog.writeError(.apiKeyMissing, to: url, now: Date(), context: nil)
      // Require the entry landed first, so the missing keys below mean something.
      let entry = try #require(firstEntry(in: url))
      #expect(entry.kind == "apiKeyMissing")
      let line = readLog(url)
      #expect(!line.contains("\"app\""))
      #expect(!line.contains("\"window\""))
      #expect(!line.contains("\"field\""))
    }
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

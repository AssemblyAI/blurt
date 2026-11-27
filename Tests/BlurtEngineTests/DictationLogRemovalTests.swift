import Foundation
import Testing

@testable import AssemblyAI
@testable import BlurtEngine

/// The delete half of the log: `InstallReset` (and `scripts/reset-lib.sh`)
/// both exist to return the machine to a preinstall state, and the transcript
/// corpus is the most sensitive thing an install leaves behind — so "removed it"
/// has to mean removed, and "there was nothing to remove" has to read as success
/// rather than as a failed reset.
@Suite("DictationLog.removeStoredLogs")
struct DictationLogRemovalTests {
  /// Both files in one temporary directory, as the real pair are — so the
  /// empty-directory sweep is exercised the way it runs in production. The
  /// directory goes when `body` returns, if the sweep left it.
  private func withTempPair(_ body: (_ dictations: URL, _ errors: URL) throws -> Void) throws {
    try withTempLogURL { dictations in
      try body(dictations, dictations.deletingLastPathComponent().appending(path: "errors.jsonl"))
    }
  }

  /// The sweep over a temporary pair, its command log beside them: never the real one.
  @discardableResult
  private func remove(dictations: URL, errors: URL) -> Bool {
    DictationLog.removeStoredLogs(
      dictations: dictations,
      errors: errors,
      commands: dictations.deletingLastPathComponent().appendingPathComponent("commands.jsonl")
    )
  }

  @Test("removes both halves of the log")
  func removesBothFiles() throws {
    try withTempPair { dictations, errors in
      DictationLog.write(transcript: "hello", to: dictations, now: Date())
      DictationLog.writeError(.apiKeyMissing, to: errors, now: Date())
      try #require(FileManager.default.fileExists(atPath: dictations.path))
      try #require(FileManager.default.fileExists(atPath: errors.path))

      #expect(remove(dictations: dictations, errors: errors))

      #expect(!FileManager.default.fileExists(atPath: dictations.path))
      #expect(!FileManager.default.fileExists(atPath: errors.path))
    }
  }

  @Test("an absent log is already in the state being asked for")
  func absentFilesSucceed() throws {
    try withTempPair { dictations, errors in
      // Nothing written: the normal case for anyone who never switched developer
      // mode on. Reporting that as a failure would put a "wasn't fully reset"
      // alert in front of every such user.
      #expect(remove(dictations: dictations, errors: errors))
    }
  }

  @Test("removes the log directory once it is empty")
  func removesEmptyDirectory() throws {
    try withTempPair { dictations, errors in
      DictationLog.write(transcript: "hello", to: dictations, now: Date())
      let directory = dictations.deletingLastPathComponent()
      try #require(FileManager.default.fileExists(atPath: directory.path))

      remove(dictations: dictations, errors: errors)

      #expect(!FileManager.default.fileExists(atPath: directory.path))
    }
  }

  @Test("leaves a directory holding anything else alone")
  func keepsNonEmptyDirectory() throws {
    try withTempPair { dictations, errors in
      DictationLog.write(transcript: "hello", to: dictations, now: Date())
      let directory = dictations.deletingLastPathComponent()
      // `~/Library/Logs/Blurt` is the app's directory, not this function's: a file
      // Blurt didn't write is not a reset's to delete.
      let bystander = directory.appendingPathComponent("crash.log")
      try Data("boom".utf8).write(to: bystander)

      remove(dictations: dictations, errors: errors)

      #expect(FileManager.default.fileExists(atPath: bystander.path))
      #expect(!FileManager.default.fileExists(atPath: dictations.path))
    }
  }
}

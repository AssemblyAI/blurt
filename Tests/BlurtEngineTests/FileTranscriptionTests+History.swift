import Foundation
import Testing

@testable import AssemblyAI
@testable import BlurtEngine

/// The saved history half of `FileTranscriptionTests`, split out to stay within
/// the lint type-body-length budget.
extension FileTranscriptionTests {
  // MARK: - History

  @Test("the history round-trips every kind, newest first, with every entry kept")
  func storeRoundTrip() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "TranscriptStoreTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = TranscriptStore(url: directory.appending(path: "history.json"))
    #expect(store.load().isEmpty)
    // Whole seconds: the dates are written ISO 8601, which keeps no fraction.
    let date = Date(timeIntervalSince1970: 1_793_380_962)
    let entries =
      [
        SavedTranscript(kind: .dictation, date: date, text: "Ship it Friday.", style: "Formal"),
        SavedTranscript(
          kind: .recording,
          date: date,
          text: "Speaker A: Hi.",
          fileURL: URL(filePath: "/tmp/Recording.m4a"),
          plainText: "Hi.",
          generatedTitle: "Greeting",
          results: ["summary": "Short."],
          customRequest: "Rhyme it."
        ),
      ]
      + (0..<120).map { index in
        SavedTranscript(kind: .file, date: date, text: "Text \(index)", fileURL: URL(filePath: "/tmp/\(index).m4a"))
      }
    try store.save(entries)
    #expect(store.load() == entries)
  }

  @Test("a dictation is titled by what was said; a file by its name")
  func titles() {
    #expect(SavedTranscript(kind: .dictation, date: .now, text: "Ship it Friday.").title == "Ship it Friday.")
    #expect(
      SavedTranscript(kind: .file, date: .now, text: "…", fileURL: URL(filePath: "/tmp/call.m4a")).title == "call.m4a")
  }

  @Test("words are counted on the plain text, across any run of whitespace")
  func wordCounts() {
    #expect(SavedTranscript(kind: .dictation, date: .now, text: "  Ship it\n\non  Friday. ").wordCount == 4)
    #expect(SavedTranscript(kind: .dictation, date: .now, text: "").wordCount == 0)
    let recording = SavedTranscript(
      kind: .recording, date: .now, text: "Speaker A: Hello there.", plainText: "Hello there."
    )
    #expect(recording.wordCount == 2)
  }

  @Test("a word needs a letter or digit: a lone dash, ellipsis or emoji isn't one")
  func wordsNeedALetterOrDigit() {
    #expect("Well — don't stop, okay?".wordCount == 4)
    #expect("Wait … 3 more 🙂".wordCount == 3)
    #expect("— … !".wordCount == 0)
    #expect("e.g. well-known".wordCount == 2)
  }

  @Test("a history that won't decode is moved aside, not overwritten")
  func corruptStore() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "TranscriptStoreTests-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "history.json")
    try Data("not json".utf8).write(to: url)
    #expect(TranscriptStore(url: url).load().isEmpty)
    let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    #expect(names.contains { $0.hasPrefix("history.corrupt-") })
    #expect(!names.contains("history.json"))
  }

  @Test("one entry that won't decode is skipped, and the file backed up first; the rest load")
  func lossyStore() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "TranscriptStoreTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = TranscriptStore(url: directory.appending(path: "history.json"))
    let good = SavedTranscript(kind: .dictation, date: Date(timeIntervalSince1970: 1_793_380_962), text: "Kept.")
    try store.save([good])
    // A second entry of a kind this build doesn't know, as a newer build might write.
    var json = try #require(
      try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appending(path: "history.json")))
        as? [[String: Any]])
    var future = json[0]
    future["id"] = UUID().uuidString
    future["kind"] = "hologram"
    json.append(future)
    try JSONSerialization.data(withJSONObject: json).write(to: directory.appending(path: "history.json"))

    #expect(store.load() == [good])
    let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    #expect(names.contains { $0.hasPrefix("history.backup-") })
    #expect(names.contains("history.json"))
  }

  @Test("file stamps go to the millisecond, so two in one second differ")
  func fileStamp() {
    let date = Date(timeIntervalSince1970: 1_793_380_962.123)
    let stamp = TranscriptStore.fileStamp(date)
    #expect(stamp.hasSuffix(".123"))
    #expect(stamp != TranscriptStore.fileStamp(date.addingTimeInterval(0.001)))
  }

  @Test("a user's file is found through its bookmark after a move")
  func bookmarkFollowsMove() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "BookmarkTests-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let original = directory.appending(path: "call.m4a")
    try Data("audio".utf8).write(to: original)
    let entry = SavedTranscript(kind: .file, date: .now, text: "Hi.", fileURL: original)
    let moved = directory.appending(path: "renamed.m4a")
    try FileManager.default.moveItem(at: original, to: moved)
    #expect(entry.audioURL?.lastPathComponent == "renamed.m4a")
    // A recording keeps its path; no bookmark.
    #expect(SavedTranscript(kind: .recording, date: .now, text: "Hi.", fileURL: moved).fileBookmark == nil)
  }
}

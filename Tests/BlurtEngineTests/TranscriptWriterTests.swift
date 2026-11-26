import Foundation
import Testing

@testable import BlurtEngine

/// The history's writes: one at a time and in order; none until the saved
/// history is read in; and the last one, made as the app quits, keeping a
/// history it never read in (#338).
@Suite("Transcript writer")
struct TranscriptWriterTests {
  private let date = Date(timeIntervalSince1970: 1_793_380_962)

  private var savedHistory: [SavedTranscript] {
    [
      SavedTranscript(kind: .dictation, date: date, text: "Saved one."),
      SavedTranscript(kind: .dictation, date: date, text: "Saved two."),
    ]
  }

  /// A store in a fresh directory, removed when `body` returns.
  private func withStore(_ body: (TranscriptStore) async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "TranscriptWriterTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    try await body(TranscriptStore(url: directory.appending(path: "history.json")))
  }

  @Test("an older list queued before the write made on quitting never lands after it")
  func keepsOrder() async throws {
    try await withStore { store in
      let writer = TranscriptWriter(store: store)
      _ = writer.open([], saved: writer.load())
      // Large, so each takes a while to encode: an older write left to run beside
      // the newer one would finish its rename last.
      for round in 0..<5 {
        writer.save((0..<5_000).map { SavedTranscript(kind: .dictation, date: date, text: "Old \(round) \($0)") })
      }
      let newest = [SavedTranscript(kind: .dictation, date: date, text: "Newest.")]
      writer.saveNow(newest)
      #expect(store.load() == newest)
      // Every older write has finished by now, so none lands after. Waited out
      // rather than trusted: a write still running would replace the list here.
      // wall-clock-ok: absence check: a slow runner can only make it pass
      try await Task.sleep(for: .milliseconds(500))
      #expect(store.load() == newest)
    }
  }

  @Test("nothing is written before the saved history is read in; opening writes what was made meanwhile")
  func holdsWritesUntilOpen() async throws {
    try await withStore { store in
      let saved = savedHistory
      try store.save(saved)
      let writer = TranscriptWriter(store: store)
      let session = [SavedTranscript(kind: .dictation, date: date, text: "This session.")]
      writer.save(session)
      #expect(store.load() == saved)
      let merged = writer.open(session, saved: writer.load())
      #expect(merged == session + saved)
      try await waitUntil { store.load() == merged }
    }
  }

  @Test("the write made on quitting merges a history not yet read in, rather than replacing it")
  func mergesUnreadHistory() async throws {
    try await withStore { store in
      let saved = savedHistory
      try store.save(saved)
      var edited = saved[1]
      edited.generatedTitle = "Edited this session"
      let session = [SavedTranscript(kind: .dictation, date: date, text: "This session."), edited]
      TranscriptWriter(store: store).saveNow(session)
      // This session's entries first, its copy of an entry winning; then the rest.
      #expect(store.load() == session + [saved[0]])
      // Once the history has been read in, the list is the whole history.
      let writer = TranscriptWriter(store: store)
      _ = writer.open([], saved: writer.load())
      writer.saveNow(session)
      #expect(store.load() == session)
    }
  }
}

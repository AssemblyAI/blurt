import Foundation
import Testing

@testable import BlurtEngine

private func makeTempCaptureLogURL() -> URL {
  let dir = FileManager.default.temporaryDirectory
    .appendingPathComponent("BlurtCaptureLogTests-\(UUID().uuidString)", isDirectory: true)
  try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  return dir.appendingPathComponent("capture-events.jsonl")
}

private func readLog(_ url: URL) -> String {
  (try? String(contentsOf: url, encoding: .utf8)) ?? ""
}

/// What one capture-sheet input event records — the raw facts a misbehaving
/// mouse is diagnosed from — and which default-valued fields stay off the line.
@Suite("DictationLog.makeCaptureEntry")
struct DictationCaptureEntryTests {
  @Test("records the event's raw facts and the outcome")
  func recordsRawFacts() {
    let entry = DictationLog.makeCaptureEntry(
      kind: "otherMouseDown", outcome: "captured", button: 3, keyCode: nil,
      flags: 0x100, isRepeat: false, binding: "Mouse 4",
      now: Date(timeIntervalSince1970: 1_700_000_000))
    #expect(entry.kind == "otherMouseDown")
    #expect(entry.outcome == "captured")
    #expect(entry.button == 3)
    #expect(entry.keyCode == nil)
    #expect(entry.flags == 0x100)
    #expect(entry.binding == "Mouse 4")
    #expect(entry.ts.hasPrefix("2023-11-14"))
  }

  @Test("a refused event carries the same raw facts, with no binding")
  func refusedEventStillCarriesFacts() throws {
    // The whole point of the log: the refusal text alone can't say what a
    // misbehaving button actually sent.
    let entry = DictationLog.makeCaptureEntry(
      kind: "keyDown", outcome: "refused-keyboard-key", button: nil, keyCode: 96,
      flags: 0, isRepeat: true, binding: nil, now: Date())
    #expect(entry.keyCode == 96)
    #expect(entry.isRepeat)
    #expect(entry.binding == nil)
    let data = try DictationLog.makeEncoder().encode(entry)
    let line = try #require(String(data: data, encoding: .utf8))
    #expect(line.contains("\"repeat\":true"))
  }

  @Test("absent and default-valued fields are omitted from the line, not written as null")
  func defaultsAreOmitted() throws {
    let entry = DictationLog.makeCaptureEntry(
      kind: "otherMouseDown", outcome: "refused-button", button: 1, keyCode: nil,
      flags: 0, isRepeat: false, binding: nil, now: Date())
    let data = try DictationLog.makeEncoder().encode(entry)
    let object = try JSONSerialization.jsonObject(with: data)
    let encoded = try #require(object as? [String: Any])
    #expect(encoded.keys.sorted() == ["button", "kind", "outcome", "ts"])
  }
}

/// The developer-mode gate — the same privacy guarantee the other two logs
/// carry: a user who never opts in has nothing on disk, so the capture sheet
/// can log unconditionally.
@Suite("DictationLog capture-log developer-mode gate")
struct DictationCaptureLogGateTests {
  @Test("with developer mode off, appendCaptureEvent writes nothing to disk")
  func gateClosedWritesNothing() {
    let url = makeTempCaptureLogURL()
    let store = DeveloperModeStore(defaults: freshDefaults())
    DictationLog.appendCaptureEvent(
      kind: "otherMouseDown", outcome: "captured", button: 3, store: store, to: url)
    DictationLog.queue.sync {}
    #expect(!FileManager.default.fileExists(atPath: url.path))
  }

  @Test("with developer mode on, appendCaptureEvent appends the event")
  func gateOpenWrites() {
    let url = makeTempCaptureLogURL()
    let store = developerModeStore(enabled: true)
    DictationLog.appendCaptureEvent(
      kind: "otherMouseDown", outcome: "refused-button", button: 1, store: store, to: url)
    DictationLog.queue.sync {}
    let line = readLog(url)
    #expect(line.contains("\"outcome\":\"refused-button\""))
    #expect(line.contains("\"button\":1"))
  }

  /// A separate sibling file: input rows must never land in the transcript
  /// corpus or the error log, whose readers expect their own shapes.
  @Test("the capture log is a sibling file of the other two")
  func writesToASiblingFile() {
    #expect(DictationLog.defaultCaptureURL != DictationLog.defaultURL)
    #expect(DictationLog.defaultCaptureURL != DictationLog.defaultErrorURL)
    #expect(
      DictationLog.defaultCaptureURL.deletingLastPathComponent()
        == DictationLog.defaultURL.deletingLastPathComponent())
    #expect(DictationLog.defaultCaptureURL.lastPathComponent == "capture-events.jsonl")
  }
}

/// The displayed capture-log location (Developer section footer) has to name
/// the file the writer actually appends to.
@Suite("DictationLog.defaultCaptureDisplayPath")
struct DictationCaptureLogDisplayPathTests {
  @Test("abbreviates the home directory and names the write target")
  func matchesTheWriteTarget() {
    let shown = DictationLog.defaultCaptureDisplayPath
    #expect(shown.hasPrefix("~/"))
    #expect(!shown.contains(NSHomeDirectory()))
    #expect(
      (shown as NSString).expandingTildeInPath
        == DictationLog.defaultCaptureURL.path(percentEncoded: false))
  }
}

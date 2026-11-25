import Foundation
import Testing

@testable import BlurtEngine

/// A dictation into a password field that is cancelled mid-paste is still
/// logged as withheld when the user presses again before the cancelled
/// pipeline reaches its log line. `cancel()` ends the phase without waiting for
/// that pipeline, so the next press can install its own `PressContext` first,
/// and that press's ordinary field must not decide what the log keeps.
@Suite("Developer-mode log after a cancelled paste", .timeLimit(.minutes(1)))
struct CancelledPasteLogTests {
  private static let passwordField = FocusedFieldContext(
    priorText: nil, selectedText: nil, windowTitle: "Sign In", fieldLabel: "Password", isSecure: true)

  @Test("a password field's transcript stays withheld when the next press lands mid-paste")
  func nextPressDoesNotUnwithholdTheLog() async throws {
    let log = RecordedLog()
    let reads = Counter()
    var seams = testSeams(log: log)
    // The first press reads a password field; the retry reads an ordinary one.
    seams.captureFieldContext = { reads.next() == 1 ? Self.passwordField : .empty }
    let injector = ParkedPasteInjector()
    let session = makeSession(
      transcriber: StubTranscriber(mode: .transcript("hunter2")), injector: injector, seams: seams)

    await session.press()
    while await session.pressContext?.targetSecurity != .secure { await Task.yield() }
    await session.release()
    await injector.waitUntilParked()
    await session.cancel()
    // The retry, accepted at once because `.cancelled` is terminal.
    await session.press()
    while await session.pressContext?.targetSecurity != .ordinary { await Task.yield() }

    await injector.letPasteFinish()
    await session.awaitPipeline()

    let entries = log.transcripts
    #expect(entries.map(\.outcome) == [.cancelled])
    #expect(!entries.contains { $0.text == "hunter2" })
    let written = entries.map {
      DictationLog.makeEntry(transcript: $0.text, context: $0.context, now: Date()).transcript
    }
    #expect(written == [DictationLog.withheldTranscript])
    await session.cancel()
  }
}

/// An injector whose paste parks until the test lets it go, then honours the
/// cancel that landed meanwhile, as `KeyInjector`'s cancellation checks do.
private actor ParkedPasteInjector: InjectorProtocol {
  private let gate = Gate()

  func insert(_ text: String, after priorText: String?, windowTitle: String?, secure: Bool) async throws {
    await gate.enter()
    try Task.checkCancellation()
  }

  func setTarget(_ focus: CapturedFocus?) async {}
  func waitUntilParked() async { await gate.waitUntilEntered() }
  func letPasteFinish() async { gate.allowToFinish() }
}

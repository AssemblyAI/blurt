import Foundation
import Testing

@testable import BlurtEngine

/// The post-release pipeline reads the press it was spawned for, never whichever
/// press is current by the time it pastes or logs. `performRelease` hands the
/// task its `PressContext`; these tests then replace the session's
/// `pressContext` while the transcript is still in flight — what a later press's
/// `beginContextCapture` does — and check that the paste's caret context and
/// the failure log both still describe the first press.
///
/// The replacement is installed directly because the public commands can't
/// reach that state with the pipeline still live: a press is refused until the
/// phase is terminal, and the cancel that makes it terminal also cancels the
/// pipeline, which then pastes and logs nothing. That is what kept the old
/// actor-wide reads correct, by ordering alone; these pin the stronger contract
/// that holds without it.
@Suite("Pipeline press context", .timeLimit(.minutes(1)))
struct PipelinePressContextTests {
  private static let firstField = FocusedFieldContext(
    priorText: "Dear Sam,",
    selectedText: nil,
    windowTitle: "Draft",
    fieldLabel: nil
  )

  /// A settled read for a different field, standing in for a later press's.
  private static func laterPress() -> PressContext {
    let later = PressContext(pressKnown: nil)
    later.store(
      resolved: TranscriptionContext(appName: "Elsewhere", priorText: "unrelated", windowTitle: "Another Window")
    )
    return later
  }

  @Test("the paste keeps its own press's caret context when another press's context is installed")
  func pasteKeepsItsPressContext() async {
    let transcriber = GatedTranscriber(text: "thanks for the notes.")
    let injector = StubInjector()
    let session = makeSession(
      transcriber: transcriber,
      injector: injector,
      clock: TestClock(),
      seams: testSeams(field: Self.firstField)
    )

    await session.press()
    while await session.pressContext?.targetSecurity != .ordinary { await Task.yield() }
    await session.release()
    await transcriber.waitUntilStarted()
    await session.installPressContext(Self.laterPress())
    await transcriber.allowToFinish()
    await session.awaitPipeline()

    #expect(await injector.inserted == ["thanks for the notes."])
    #expect(await injector.insertedPrior == ["Dear Sam,"])
    #expect(await injector.insertedWindowTitles == ["Draft"])
  }

  @Test("a failed paste is logged against its own press when another press's context is installed")
  func failedPasteLogsItsPressContext() async {
    let log = RecordedLog()
    let transcriber = GatedTranscriber(text: "thanks for the notes.")
    let injector = StubInjector()
    await injector.setError(BlurtError.accessibilityPermissionMissing)
    let session = makeSession(
      transcriber: transcriber,
      injector: injector,
      clock: TestClock(),
      seams: testSeams(field: Self.firstField, log: log)
    )

    await session.press()
    while await session.pressContext?.targetSecurity != .ordinary { await Task.yield() }
    await session.release()
    await transcriber.waitUntilStarted()
    await session.installPressContext(Self.laterPress())
    await transcriber.allowToFinish()
    await session.awaitPipeline()

    #expect(await session.phase == .failed(.accessibilityPermissionMissing))
    #expect(log.failureNames == [BlurtError.accessibilityPermissionMissing.diagnosticName])
    #expect(log.failures.map(\.context?.windowTitle) == ["Draft"])
    #expect(log.failures.map(\.context?.priorText) == ["Dear Sam,"])
    #expect(log.transcripts.map(\.context?.windowTitle) == ["Draft"])
  }
}

extension DictationSession {
  /// Replaces the current press's context as a later press's
  /// `beginContextCapture` would, without running a press.
  func installPressContext(_ press: PressContext?) {
    pressContext = press
  }
}

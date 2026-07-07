import Foundation
import Testing

@testable import BlurtEngine

/// `DictationSession.firstValue(of:within:clock:)` — the bounded wait
/// `runTranscribeInject` puts on the press-time AX field-context read, so an
/// unresponsive frontmost app delays the transcript by at most
/// `contextWaitBudget` (the utterance just goes out with less priming) instead
/// of the capture's multi-second AX-timeout worst case.
@Suite("DictationSession context wait", .timeLimit(.minutes(1)))
struct ContextWaitTests {

  @Test("a context that resolved during speech is returned without waiting")
  func finishedReadReturnsImmediately() async {
    let (stream, feed) = AsyncStream.makeStream(
      of: TranscriptionContext?.self, bufferingPolicy: .bufferingNewest(1))
    let context = TranscriptionContext(appName: "Mail", priorText: "Hi team,")
    feed.yield(context)
    feed.finish()

    // The clock is never advanced: a buffered result must come back without the
    // race ever sleeping out its budget (a wall-clock sleep would hang here).
    let got = await DictationSession.firstValue(
      of: stream, within: .milliseconds(500), clock: TestClock())
    #expect(got == context)
  }

  @Test("an empty context read yields nil promptly, not a timeout wait")
  func emptyReadReturnsNilImmediately() async {
    let (stream, feed) = AsyncStream.makeStream(
      of: TranscriptionContext?.self, bufferingPolicy: .bufferingNewest(1))
    feed.yield(nil)
    feed.finish()

    let got = await DictationSession.firstValue(
      of: stream, within: .milliseconds(500), clock: TestClock())
    #expect(got == nil)
  }

  @Test("a hung context read is abandoned once the budget elapses")
  func hungReadTimesOut() async {
    // The feed never yields and is kept alive past the assertion — modeling an
    // AX read wedged inside an unresponsive frontmost app.
    let (stream, feed) = AsyncStream.makeStream(
      of: TranscriptionContext?.self, bufferingPolicy: .bufferingNewest(1))
    let clock = TestClock()

    async let got = DictationSession.firstValue(
      of: stream, within: .milliseconds(500), clock: clock)
    // Let the timeout racer park on the virtual clock before advancing past its
    // deadline (the drain pattern the race suites use).
    for _ in 0..<1000 { await Task.yield() }
    clock.advance(by: .milliseconds(500))

    #expect(await got == nil)
    feed.finish()
  }
}

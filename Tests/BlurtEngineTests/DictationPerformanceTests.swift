import XCTest

@testable import BlurtEngine

/// Performance-regression guard for the dictation hot paths. Swift Testing has no
/// performance API yet, so this stays XCTest (the two frameworks coexist in this
/// target).
///
/// Rather than XCTest baselines — which SPM's `swift test` doesn't read and which
/// are keyed to a specific device, so they can't gate on CI — these assert
/// explicit wall-clock budgets. The budgets are deliberately generous (orders of
/// magnitude above the sub-millisecond stubbed timings, and above the slowdown
/// the ThreadSanitizer/AddressSanitizer passes add): they aren't there to pin an
/// exact number but to fail loudly if the hot path regresses grossly — e.g. a
/// blocking call, an accidental sleep, or synchronous I/O sneaking onto it. The
/// os_signpost intervals `DictationSession` emits (PressStart / TranscribeInject)
/// remain for precise Instruments timing.
final class DictationPerformanceTests: XCTestCase {
  /// Median of `iterations` timed runs, dropping the first (warm-up) sample so
  /// one-time lazy init (loggers, formatters) doesn't skew the budget.
  private func medianDuration(iterations: Int, of body: () async -> Void) async -> Duration {
    var samples: [Duration] = []
    for i in 0..<iterations {
      let elapsed = await ContinuousClock().measure { await body() }
      if i > 0 { samples.append(elapsed) }
    }
    return samples.sorted()[samples.count / 2]
  }

  private func makeSession() -> DictationSession {
    DictationSession(
      mic: StubMicCapture(),
      transcriber: StubTranscriber(mode: .yieldChunks(["hello world"])),
      injector: StubInjector())
  }

  /// The release → transcribe → inject hot path (STT round trip + paste), stubbed.
  func testTranscribeInjectWithinBudget() async {
    let median = await medianDuration(iterations: 7) {
      let session = makeSession()
      await session.press()
      await session.release()
      await session.waitForIdle()
    }
    // Stubbed this is well under a millisecond; 500 ms is a gross-regression trip.
    XCTAssertLessThan(
      median, .milliseconds(500),
      "transcribe→inject hot path regressed: median \(median) over budget")
  }

  /// The press → `.recording` startup path (focus capture + mic start), stubbed.
  func testPressStartupWithinBudget() async {
    let median = await medianDuration(iterations: 7) {
      let session = makeSession()
      await session.press()
      await session.cancel()  // tear down so the mic/recording doesn't linger
    }
    XCTAssertLessThan(
      median, .milliseconds(500),
      "press startup path regressed: median \(median) over budget")
  }
}

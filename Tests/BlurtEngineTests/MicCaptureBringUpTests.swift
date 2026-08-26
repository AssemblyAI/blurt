import Foundation
import Testing

@testable import BlurtEngine

/// The bring-up race: a teardown arriving while the input device is still
/// opening must be serviced, not queued behind the open.
///
/// `record()` opens the device, and how long that takes is the hardware's
/// business — ~100 ms on AirPods, ~180 ms on the built-in mic, ~600 ms on a USB
/// interface. Run inline on the actor it blocked every other call for that whole
/// window (measured: 578 ms on a 635 ms open); off-actor the same teardown takes
/// microseconds. Hence the absolute budget below rather than a ratio against a
/// calibration run: an unblocked `cancelCapture()` is one actor hop and a nil
/// check either way, so the budget holds on every input, and a regression fails
/// it on any device whose open outlasts the budget — which is all of them.
@Suite(
  "MicCapture bring-up (live)",
  ConditionTrait.requiresLiveAudio,
  .tags(.liveAudio),
  .serialized,
  .timeLimit(.minutes(1)))
struct MicCaptureBringUpTests {
  /// Generous next to the ~24 µs an unblocked teardown measures, and far below
  /// the tens-to-hundreds of ms a blocked one costs on any real input.
  private static let teardownBudget = Duration.milliseconds(10)

  @Test("a teardown during the device open isn't blocked by it")
  func teardownDuringOpenIsNotBlocked() async throws {
    await LiveAudioDevice.acquire()
    defer { LiveAudioDevice.release() }

    // An unqueued teardown mid-bring-up — the shape a host that doesn't
    // serialize its own commands produces. `DictationSession` does serialize
    // (its release and cancel run only after the press turn completes), but this
    // is a public actor and the contract has to hold without that.
    let mic = MicCapture(deviceSelection: { .systemDefault })

    // Warm first, exactly as the app does at launch, so what is measured below
    // is the property under test and not this process's first touch of the
    // capture stack. That first touch is ~185 ms — most of it the first device
    // query, which `start()` makes inline while resolving the selection — and
    // absorbing it is `warmUp()`'s entire job. Without this the measurement
    // reports a real cost that a launched app has already paid.
    await mic.warmUp()

    // An unstructured `Task` rather than `async let`, only because the
    // `#expect(throws:)` below can't capture an `async let` variable.
    let press = Task { try await mic.start() }
    // 30 ms is a bracket, not a guarantee: it has to clear the ~5 ms session
    // build (cancelling before the open is reached would pass even if `record()`
    // went back to blocking the actor) and still land inside the open, whose
    // fastest measurement here is ~80 ms. Both ends matter, so the outcome is
    // checked below rather than assumed.
    try await Task.sleep(for: .milliseconds(30))

    let cancelCost = await ContinuousClock().measure {
      try? await mic.cancelCapture()
    }

    // Where the cancel actually landed, straight from the press: an abandoned
    // bring-up throws `CancellationError` from one of the three
    // `checkStillWanted` points instead of installing its recorder.
    var pressFailure: Error?
    do {
      try await press.value
    } catch {
      pressFailure = error
    }
    let abandonedMidBringUp = pressFailure is CancellationError

    // An unrelated capture failure is its own report, not evidence about the
    // bracket — otherwise a mic that never delivers reads as "too fast".
    if let pressFailure, !abandonedMidBringUp {
      Issue.record("start() failed for an unrelated reason: \(pressFailure)")
    }

    // Judged before the budget, because the two are different failures. If the
    // bring-up finished inside the wait — a virtual or aggregate input that
    // opens *and* delivers non-silent audio in under 30 ms — then
    // `cancelCapture()` took the installed path, whose inline `stopRunning()` is
    // documented at 19–41 ms, and asserting the teardown budget on that reports
    // "the actor was blocked" about an actor that was never blocked. Naming the
    // bracket separately is what stops one failure wearing the other's message.
    #expect(
      abandonedMidBringUp,
      """
      the bring-up completed inside the 30 ms wait, so the teardown below measured an installed \
      recorder rather than one mid-open — this input is too fast for a timing bracket, and pinning \
      the property on it wants an injectable recorder rather than a longer sleep
      """)

    if abandonedMidBringUp {
      #expect(
        cancelCost < Self.teardownBudget,
        "cancelCapture took \(cancelCost) while the device was still opening — the actor was blocked"
      )
    }
  }
}

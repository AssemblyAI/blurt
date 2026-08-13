import Foundation
import Testing

@testable import BlurtEngine

/// Behavior in the `.connecting` window — the up-to-2.5 s stretch
/// `MicCapture.start()` holds while a Bluetooth route brings the mic up. Before
/// the liveness gate, `start()` returned in microseconds and nothing could land
/// mid-press; now things can, so pin what happens when they do.
@Suite("DictationSession mic bring-up", .timeLimit(.minutes(1)))
struct DictationSessionBringUpTests {
  @Test("a cancel landing during the bring-up never reaches .recording")
  func cancelDuringBringUpSkipsRecording() async throws {
    // The regression this guards: the press used to finish the bring-up, claim
    // `.recording` and fire the start chime — cueing "speak now" for a capture
    // the user had already cancelled — and only then get torn down by the queued
    // cancel. `.recording` must never be published on this path, because
    // `RecordingCueGate` chimes on exactly that edge.
    let mic = GatedStartMic()
    let session = DictationSession(
      mic: mic, transcriber: StubTranscriber(mode: .transcript("never")),
      injector: StubInjector(), seams: .offline)

    let stream = await session.phaseStream()
    let pressed = Task { await session.press() }
    await mic.waitUntilStartEntered()  // press() is suspended inside mic.start()
    // Direct `cancel()`, not `submit(.cancel)`: `submit`'s consumer is serial, so
    // a submitted cancel cannot even be *recorded* until the press returns. See
    // the note in `performPress` — this covers callers that can `await`.
    let cancelled = Task { await session.cancel() }
    await session.awaitCancelRequest()
    await mic.allowStartToFinish()
    await pressed.value
    await cancelled.value

    var seen: [PipelinePhase] = []
    for await phase in stream {
      seen.append(phase)
      if phase.isTerminal, phase != .idle { break }
    }

    #expect(seen == [.idle, .connecting, .cancelled])
    // Spelled out separately so a failure names the actual regression rather
    // than just an unequal array.
    #expect(!seen.contains(.recording))
    // The mic came up during the wait, so it has to have been torn down — and
    // through the discarding teardown, not `stop()`.
    #expect(await mic.cancelCaptureCalls == 1)
  }

  @Test("a submitted cancel preempts the bring-up instead of queueing behind it")
  func submittedCancelPreemptsBringUp() async throws {
    // The app's cancel door is `submit`, and its consumer is serial — so a
    // `.cancel` submitted during a press cannot reach `cancel()` until that press
    // returns. With `MicCapture.start()` holding until the mic is live, that made
    // Escape invisible for up to `MicLiveness.bluetoothTimeout`. `submit` now
    // records the intent and cancels the in-flight press itself, without waiting
    // for a turn on an actor the press is holding.
    let mic = GatedStartMic()
    let session = DictationSession(
      mic: mic, transcriber: StubTranscriber(mode: .transcript("never")),
      injector: StubInjector(), seams: .offline)

    let stream = await session.phaseStream()
    session.submit(.press)
    await mic.waitUntilStartEntered()  // the consumer is now blocked inside this press

    session.submit(.cancel)
    // Both effects have to be observable *before* the press is released, which is
    // the whole point — neither needs the consumer to get a turn.
    #expect(session.cancelRequested)
    #expect(session.inFlightPress?.isCancelled == true)

    await mic.allowStartToFinish()

    var seen: [PipelinePhase] = []
    for await phase in stream {
      seen.append(phase)
      if phase.isTerminal, phase != .idle { break }
    }
    #expect(seen.last == .cancelled)
    #expect(!seen.contains(.recording))
    #expect(await mic.cancelCaptureCalls == 1)
  }

  @Test("a cancel that aborts the bring-up doesn't leak its request into the next press")
  func abortedBringUpLeavesNoStandingCancel() async throws {
    // The route where `start()` actually throws — a cancel landing *inside* the
    // liveness wait, which is what the real `MicCapture` does. `cancel()`'s
    // `.connecting` branch claims the phase and returns without enqueueing
    // `performCancel`, so the press's catch is the only place left that can
    // consume the request it recorded. When it didn't, the flag survived, and the
    // *next* press read it after a perfectly good `mic.start()` and cancelled
    // itself — one dead dictation for every cancelled bring-up.
    let mic = GatedStartMic()
    await mic.setThrowsIfCancelled(true)
    let session = DictationSession(
      mic: mic, transcriber: StubTranscriber(mode: .transcript("Hello world.")),
      injector: StubInjector(), seams: .offline)

    let pressed = Task { await session.press() }
    await mic.waitUntilStartEntered()
    await session.cancel()
    await mic.allowStartToFinish()
    await pressed.value

    #expect(await session.phase == .cancelled)
    #expect(!session.cancelRequested)

    // The proof that matters: the next press records normally.
    await session.press()
    #expect(await session.phase == .recording)
  }
}

import Foundation
import Testing

@testable import BlurtEngine

@Suite("DictationSession", .timeLimit(.minutes(1)))
struct DictationSessionTests {

  @Test("press from idle transitions to recording")
  func pressIdleToRecording() async throws {
    let fixture = makeSession(mode: .transcript("hello"))

    await fixture.session.press()

    #expect(await fixture.session.phase == .recording)
    #expect(await fixture.mic.startCalls == 1)
  }
}

extension DictationSessionTests {
  @Test("happy path: press → release → transcribe → inject")
  func happyPath() async throws {
    // The dictation API returns the already-cleaned text in one response.
    let fixture = makeSession(mode: .transcript("Hello world."))

    await fixture.session.press()
    await fixture.session.release()
    await fixture.session.waitForIdle()

    #expect(await fixture.session.phase == .pasted)
    #expect(await fixture.injector.inserted == ["Hello world."])
    // The captured caret context rides along with the insert. `makeSession`
    // captures nothing by default, so nil is the whole expected value rather
    // than an argument count — what the context actually threads through is
    // `DictationSessionContextTests`.
    #expect(await fixture.injector.insertedPrior == [nil])
  }

  @Test("a too-short clip is dropped as a silent no-op, not sent to STT")
  func tooShortClipNoOps() async throws {
    let fixture = makeSession(mode: .transcript("should not be used"))
    // Below SyncSTTLimits.minPCMBytes (3200 at 16 kHz) — an accidental brief
    // tap the endpoint would reject with a 400.
    await fixture.mic.setPCM(Data(count: 6))

    await fixture.session.press()
    await fixture.session.release()
    await fixture.session.waitForIdle()

    #expect(await fixture.session.phase == .idle)
    #expect(await fixture.injector.inserted.isEmpty)
  }
}

extension DictationSessionTests {
  @Test("STT failure surfaces .failed and skips injection")
  func sttFailure() async throws {
    struct Boom: Error {}
    let fixture = makeSession(mode: .throwError(Boom()))

    await fixture.session.press()
    await fixture.session.release()
    await fixture.session.waitForIdle()

    if case .failed(.sttFailed) = await fixture.session.phase {
      // ok
    } else {
      Issue.record("expected .failed(.sttFailed), got \(await fixture.session.phase)")
    }
    #expect(await fixture.injector.inserted.isEmpty)
  }

  @Test("BlurtError from transcriber surfaces verbatim, not wrapped in sttFailed")
  func transcriberBlurtErrorSurfaces() async throws {
    let fixture = makeSession(mode: .throwError(BlurtError.apiKeyMissing))

    await fixture.session.press()
    await fixture.session.release()
    await fixture.session.waitForIdle()

    #expect(await fixture.session.phase == .failed(.apiKeyMissing))
    #expect(await fixture.injector.inserted.isEmpty)
  }
}

extension DictationSessionTests {
  @Test("press after .failed succeeds (state recovers)")
  func pressAfterFailure() async throws {
    struct Boom: Error {}
    let fixture = makeSession(mode: .throwError(Boom()))

    // First run: fail in STT
    await fixture.session.press()
    await fixture.session.release()
    await fixture.session.waitForIdle()
    if case .failed = await fixture.session.phase {
    } else {
      Issue.record("expected .failed after STT throws")
    }

    // Second run: press() must be allowed again — verify it changes phase.
    await fixture.session.press()
    #expect(await fixture.session.phase == .recording)
  }
}

extension DictationSessionTests {
  @Test("mic.start failure surfaces .failed(.audioCaptureFailed), stays out of recording")
  func micStartFailureSurfaces() async throws {
    struct Boom: Error {}
    let fixture = makeSession(mode: .transcript("never"))
    await fixture.mic.setStartError(Boom())

    await fixture.session.press()

    if case .failed(.audioCaptureFailed) = await fixture.session.phase {
      // ok
    } else {
      Issue.record("expected .failed(.audioCaptureFailed), got \(await fixture.session.phase)")
    }
  }

  @Test("empty transcript returns to idle without injecting")
  func emptyTranscriptReturnsToIdle() async throws {
    // The API yielded only whitespace (e.g. silence) — nothing to inject.
    let fixture = makeSession(mode: .transcript("   "))

    await fixture.session.press()
    await fixture.session.release()
    await fixture.session.waitForIdle()

    #expect(await fixture.session.phase == .idle)
    #expect(await fixture.injector.inserted.isEmpty)
  }

  @Test("untyped injector failure surfaces .failed(.targetAppLost)")
  func injectorFailureSurfaces() async throws {
    struct Boom: Error {}
    let fixture = makeSession(mode: .transcript("Hello world."))
    await fixture.injector.setError(Boom())

    await fixture.session.press()
    await fixture.session.release()
    await fixture.session.waitForIdle()

    #expect(await fixture.session.phase == .failed(.targetAppLost))
  }

  @Test("injector BlurtError surfaces verbatim, not relabeled as targetAppLost")
  func injectorBlurtErrorPassesThrough() async throws {
    let fixture = makeSession(mode: .transcript("Hello world."))
    // A typed BlurtError from the injector must reach the UI as-is rather
    // than being flattened to .targetAppLost.
    await fixture.injector.setError(BlurtError.accessibilityPermissionMissing)

    await fixture.session.press()
    await fixture.session.release()
    await fixture.session.waitForIdle()

    #expect(await fixture.session.phase == .failed(.accessibilityPermissionMissing))
  }

  @Test("no editable target surfaces the quiet .noTarget phase, not a failure")
  func noEditableTargetIsQuiet() async throws {
    let fixture = makeSession(mode: .transcript("Hello world."))
    // The injector left the transcript on the clipboard and signalled there was
    // nowhere to type — the session should treat that as the quiet .noTarget
    // outcome, not a red .failed error.
    await fixture.injector.setError(BlurtError.noEditableTarget)

    await fixture.session.press()
    await fixture.session.release()
    await fixture.session.waitForIdle()

    #expect(await fixture.session.phase == .noTarget)
  }

  @Test("lost target surfaces the quiet .noTarget phase, not a failure")
  func targetAppLostIsQuiet() async throws {
    let fixture = makeSession(mode: .transcript("Hello world."))
    // The target app quit (or refused activation) before the paste; the
    // injector left the transcript on the clipboard, so the session degrades
    // this to the quiet "copied" outcome rather than a red .failed error.
    await fixture.injector.setError(BlurtError.targetAppLost)

    await fixture.session.press()
    await fixture.session.release()
    await fixture.session.waitForIdle()

    #expect(await fixture.session.phase == .noTarget)
  }

  @Test("mic.stop failure surfaces .failed(.audioCaptureFailed), no injection")
  func micStopFailureSurfaces() async throws {
    struct Boom: Error {}
    let fixture = makeSession(mode: .transcript("never"))
    await fixture.mic.setStopError(Boom())

    await fixture.session.press()
    await fixture.session.release()
    await fixture.session.waitForIdle()

    if case .failed(.audioCaptureFailed) = await fixture.session.phase {
      // ok
    } else {
      Issue.record("expected .failed(.audioCaptureFailed), got \(await fixture.session.phase)")
    }
    #expect(await fixture.injector.inserted.isEmpty)
  }

  @Test("auto-release after maxRecordingSeconds")
  func autoRelease() async throws {
    let fixture = makeSession(mode: .transcript("Timed out text."), maxRecordingSeconds: 0.05)

    await fixture.session.press()
    await fixture.session.waitForIdle()  // auto-release fires release() within 50ms

    #expect(await fixture.injector.inserted == ["Timed out text."])
  }

  @Test("phaseStream yields the current phase then transitions through to terminal")
  func phaseStreamObservesTransitions() async throws {
    let session = makeSession(mode: .transcript("Hi.")).session

    // Subscribe while recording (phase is non-terminal, so the initial yield
    // doesn't immediately satisfy the terminal check).
    await session.press()
    let stream = await session.phaseStream()

    func firstTerminal(_ stream: AsyncStream<PipelinePhase>) async -> PipelinePhase? {
      for await phase in stream where phase.isTerminal { return phase }
      return nil
    }

    async let terminal = firstTerminal(stream)
    await session.release()

    #expect(await terminal == .pasted)
  }

  @Test("press claims .connecting while the mic comes up, then .recording")
  func pressPublishesConnectingBeforeRecording() async throws {
    // The whole point of the phase: `mic.start()` now holds until the input
    // route actually delivers frames (~1–2 s on a Bluetooth link), and the
    // overlay needs something to show for that whole window — while the start
    // chime deliberately waits for `.recording`. So `.connecting` must be
    // *published*, not merely passed through: a `setPhase` skipped here leaves
    // the pill absent for the entire bring-up, and the press looks ignored.
    let fixture = makeSession()

    let stream = await fixture.session.phaseStream()
    fixture.session.submit(.press)

    var seen: [PipelinePhase] = []
    for await phase in stream {
      seen.append(phase)
      if phase == .recording { break }
    }

    // The subscription's initial yield is the current phase (.idle), then the
    // press's two transitions in order.
    #expect(seen == [.idle, .connecting, .recording])

    await fixture.session.cancel()
  }

  @Test("cancel during active recording stops mic, discards audio, and transitions to .cancelled")
  func cancelDuringRecording() async throws {
    let fixture = makeSession(mode: .transcript("Hello"))

    await fixture.session.press()
    #expect(await fixture.session.phase == .recording)

    await fixture.session.cancel()
    #expect(await fixture.session.phase == .cancelled)
    #expect(await fixture.mic.stopCalls == 1)
    #expect(await fixture.injector.inserted.isEmpty)
  }

  @Test("a cancel tears the mic down through cancelCapture, a release through stop")
  func cancelUsesTheDiscardingTeardown() async throws {
    // The two teardowns want opposite things, so the session must not conflate
    // them. `stop()` may legitimately spend time preserving the audio —
    // `MicCapture` waits out a Bluetooth link's tail before ending the
    // recording — while a cancel has nothing to preserve and must take effect at
    // once. Routing a cancel through `stop()` would make the user's cancel pay
    // that linger to save audio it is about to delete.
    let cancelled = makeSession()
    await cancelled.session.press()
    await cancelled.session.cancel()
    #expect(await cancelled.mic.cancelCaptureCalls == 1)

    let released = makeSession()
    await released.session.press()
    await released.session.release()
    await released.session.waitForIdle()
    #expect(await released.mic.cancelCaptureCalls == 0)
    #expect(await released.mic.stopCalls == 1)
  }
}

// Guard/no-op behaviors and phase-stream supersession live in
// `DictationSessionGuardTests.swift` (same collaborators and stubs), split out
// to stay within the lint file-length budget. The `onTranscriptDelivered`
// side-channel tests live in `DictationSessionTranscriptTests.swift` for the
// same reason.

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
}

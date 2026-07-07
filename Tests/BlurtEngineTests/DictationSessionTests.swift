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
    // The Sync API returns the already-cleaned transcript in one response.
    let fixture = makeSession(mode: .transcript("Hello world."))

    await fixture.session.press()
    await fixture.session.release()
    await fixture.session.waitForIdle()

    #expect(await fixture.session.phase == .pasted)
    #expect(await fixture.injector.inserted == ["Hello world."])
    // The captured caret context rides along with the insert (its value is
    // host-dependent in a test run, but the argument must be forwarded).
    #expect(await fixture.injector.insertedPrior.count == 1)
  }

  @Test("a too-short clip is dropped as a silent no-op, not sent to STT")
  func tooShortClipNoOps() async throws {
    let fixture = makeSession(mode: .transcript("should not be used"))
    // Below SyncSTTLimits.minPCMBytes (3200 at 16 kHz) — an accidental brief
    // tap the Sync endpoint would reject with a 400.
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
    // Sync API yielded only whitespace (e.g. silence) — nothing to inject.
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
}

// Guard/no-op behaviors and phase-stream supersession live in
// `DictationSessionGuardTests.swift` (same collaborators and stubs), split out
// to stay within the lint file-length budget. The `onTranscriptDelivered`
// side-channel tests live in `DictationSessionTranscriptTests.swift` for the
// same reason.

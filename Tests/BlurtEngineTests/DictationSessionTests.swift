import Foundation
import Testing

@testable import BlurtEngine

@Suite("DictationSession", .timeLimit(.minutes(1)))
struct DictationSessionTests {

  @Test("press from idle transitions to recording")
  func pressIdleToRecording() async throws {
    let mic = StubMicCapture()
    let stt = StubTranscriber(mode: .transcript("hello"))
    let injector = StubInjector()
    let session = DictationSession(
      mic: mic, transcriber: stt, injector: injector
    )

    await session.press()

    #expect(await session.phase == .recording)
    #expect(await mic.startCalls == 1)
  }
}

extension DictationSessionTests {
  @Test("happy path: press → release → transcribe → inject")
  func happyPath() async throws {
    let mic = StubMicCapture()
    // The Sync API returns the already-cleaned transcript in one response.
    let stt = StubTranscriber(mode: .transcript("Hello world."))
    let injector = StubInjector()
    let session = DictationSession(
      mic: mic, transcriber: stt, injector: injector
    )

    await session.press()
    await session.release()
    await session.waitForIdle()

    #expect(await session.phase == .pasted)
    #expect(await injector.inserted == ["Hello world."])
  }

  @Test("a too-short clip is dropped as a silent no-op, not sent to STT")
  func tooShortClipNoOps() async throws {
    let mic = StubMicCapture()
    // Below SyncSTTLimits.minSamples (1600 at 16 kHz) — an accidental brief tap
    // the Sync endpoint would reject with a 400.
    await mic.setSamples([0.0, 0.1, 0.2])
    let stt = StubTranscriber(mode: .transcript("should not be used"))
    let injector = StubInjector()
    let session = DictationSession(mic: mic, transcriber: stt, injector: injector)

    await session.press()
    await session.release()
    await session.waitForIdle()

    #expect(await session.phase == .idle)
    #expect(await injector.inserted.isEmpty)
  }
}

extension DictationSessionTests {
  @Test("STT failure surfaces .failed and skips injection")
  func sttFailure() async throws {
    struct Boom: Error {}
    let mic = StubMicCapture()
    let stt = StubTranscriber(mode: .throwError(Boom()))
    let injector = StubInjector()
    let session = DictationSession(
      mic: mic, transcriber: stt, injector: injector
    )

    await session.press()
    await session.release()
    await session.waitForIdle()

    if case .failed(.sttFailed) = await session.phase {
      // ok
    } else {
      Issue.record("expected .failed(.sttFailed), got \(await session.phase)")
    }
    #expect(await injector.inserted.isEmpty)
  }

  @Test("BlurtError from transcriber surfaces verbatim, not wrapped in sttFailed")
  func transcriberBlurtErrorSurfaces() async throws {
    let mic = StubMicCapture()
    let stt = StubTranscriber(mode: .throwError(BlurtError.apiKeyMissing))
    let injector = StubInjector()
    let session = DictationSession(
      mic: mic, transcriber: stt, injector: injector
    )

    await session.press()
    await session.release()
    await session.waitForIdle()

    #expect(await session.phase == .failed(.apiKeyMissing))
    #expect(await injector.inserted.isEmpty)
  }
}

extension DictationSessionTests {
  @Test("press after .failed succeeds (state recovers)")
  func pressAfterFailure() async throws {
    struct Boom: Error {}
    let mic = StubMicCapture()
    let stt = StubTranscriber(mode: .throwError(Boom()))
    let injector = StubInjector()
    let session = DictationSession(
      mic: mic, transcriber: stt, injector: injector
    )

    // First run: fail in STT
    await session.press()
    await session.release()
    await session.waitForIdle()
    if case .failed = await session.phase {
    } else {
      Issue.record("expected .failed after STT throws")
    }

    // Second run: should be allowed; we'll use a fresh transcriber stub via separate session
    // But the bug is the GUARD, not the stubs: just verify press() now changes phase.
    await session.press()
    #expect(await session.phase == .recording)
  }
}

extension DictationSessionTests {
  @Test("mic.start failure surfaces .failed(.audioCaptureFailed), stays out of recording")
  func micStartFailureSurfaces() async throws {
    struct Boom: Error {}
    let mic = StubMicCapture()
    await mic.setStartError(Boom())
    let stt = StubTranscriber(mode: .transcript("never"))
    let injector = StubInjector()
    let session = DictationSession(
      mic: mic, transcriber: stt, injector: injector
    )

    await session.press()

    if case .failed(.audioCaptureFailed) = await session.phase {
      // ok
    } else {
      Issue.record("expected .failed(.audioCaptureFailed), got \(await session.phase)")
    }
  }

  @Test("empty transcript returns to idle without injecting")
  func emptyTranscriptReturnsToIdle() async throws {
    let mic = StubMicCapture()
    // Sync API yielded only whitespace (e.g. silence) — nothing to inject.
    let stt = StubTranscriber(mode: .transcript("   "))
    let injector = StubInjector()
    let session = DictationSession(
      mic: mic, transcriber: stt, injector: injector
    )

    await session.press()
    await session.release()
    await session.waitForIdle()

    #expect(await session.phase == .idle)
    #expect(await injector.inserted.isEmpty)
  }

  @Test("injector failure surfaces .failed(.targetAppLost)")
  func injectorFailureSurfaces() async throws {
    struct Boom: Error {}
    let mic = StubMicCapture()
    let stt = StubTranscriber(mode: .transcript("Hello world."))
    let injector = StubInjector()
    await injector.setError(Boom())
    let session = DictationSession(
      mic: mic, transcriber: stt, injector: injector
    )

    await session.press()
    await session.release()
    await session.waitForIdle()

    #expect(await session.phase == .failed(.targetAppLost))
  }

  @Test("injector BlurtError surfaces verbatim, not relabeled as targetAppLost")
  func injectorBlurtErrorPassesThrough() async throws {
    let mic = StubMicCapture()
    let stt = StubTranscriber(mode: .transcript("Hello world."))
    let injector = StubInjector()
    // A typed BlurtError from the injector must reach the UI as-is rather
    // than being flattened to .targetAppLost.
    await injector.setError(BlurtError.accessibilityPermissionMissing)
    let session = DictationSession(
      mic: mic, transcriber: stt, injector: injector
    )

    await session.press()
    await session.release()
    await session.waitForIdle()

    #expect(await session.phase == .failed(.accessibilityPermissionMissing))
  }

  @Test("no editable target surfaces the quiet .noTarget phase, not a failure")
  func noEditableTargetIsQuiet() async throws {
    let mic = StubMicCapture()
    let stt = StubTranscriber(mode: .transcript("Hello world."))
    let injector = StubInjector()
    // The injector left the transcript on the clipboard and signalled there was
    // nowhere to type — the session should treat that as the quiet .noTarget
    // outcome, not a red .failed error.
    await injector.setError(BlurtError.noEditableTarget)
    let session = DictationSession(mic: mic, transcriber: stt, injector: injector)

    await session.press()
    await session.release()
    await session.waitForIdle()

    #expect(await session.phase == .noTarget)
  }

  @Test("mic.stop failure surfaces .failed(.audioCaptureFailed), no injection")
  func micStopFailureSurfaces() async throws {
    struct Boom: Error {}
    let mic = StubMicCapture()
    await mic.setStopError(Boom())
    let stt = StubTranscriber(mode: .transcript("never"))
    let injector = StubInjector()
    let session = DictationSession(
      mic: mic, transcriber: stt, injector: injector
    )

    await session.press()
    await session.release()
    await session.waitForIdle()

    if case .failed(.audioCaptureFailed) = await session.phase {
      // ok
    } else {
      Issue.record("expected .failed(.audioCaptureFailed), got \(await session.phase)")
    }
    #expect(await injector.inserted.isEmpty)
  }

  @Test("auto-release after maxRecordingSeconds")
  func autoRelease() async throws {
    let mic = StubMicCapture()
    let stt = StubTranscriber(mode: .transcript("Timed out text."))
    let injector = StubInjector()
    let session = DictationSession(
      mic: mic, transcriber: stt, injector: injector,
      maxRecordingSeconds: 0.05
    )

    await session.press()
    await session.waitForIdle()  // auto-release fires release() within 50ms

    #expect(await injector.inserted == ["Timed out text."])
  }

  @Test("phaseStream yields the current phase then transitions through to terminal")
  func phaseStreamObservesTransitions() async throws {
    let mic = StubMicCapture()
    let stt = StubTranscriber(mode: .transcript("Hi."))
    let injector = StubInjector()
    let session = DictationSession(
      mic: mic, transcriber: stt, injector: injector
    )

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
    let mic = StubMicCapture()
    let stt = StubTranscriber(mode: .transcript("Hello"))
    let injector = StubInjector()
    let session = DictationSession(
      mic: mic, transcriber: stt, injector: injector
    )

    await session.press()
    #expect(await session.phase == .recording)

    await session.cancel()
    #expect(await session.phase == .cancelled)
    #expect(await mic.stopCalls == 1)
    #expect(await injector.inserted.isEmpty)
  }
}

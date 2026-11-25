import AVFoundation
import BlurtEngine
import Foundation
import Synchronization
import Testing

@testable import BlurtiOS
@testable import BlurtiOSCore

/// Every way the window's microphone can fail, said as the keyboard's reason
/// and the home screen's sentence (`CaptureFailure`), the silence watchdog
/// (`UtteranceFeed`), the session's reason names, and the simulator's faults.
@Suite("Capture failures")
struct CaptureFailureTests {
  private struct Stranger: Error {}

  /// Every `ListeningSourceFailure`, with its reason.
  private static let failures: [(ListeningSourceFailure, FailureReason)] = [
    (.windowClosed, .sessionOff),
    (.noInputDevice, .micBusy),
    (.interrupted(reason: "audioDeviceInUseByAnotherClient"), .interrupted),
    (.runtimeError(code: -12_782), .micBusy),
    (.configureFailed(code: -50), .micBusy),
    (.inputSilent, .micSilent),
    (.couldNotResume, .interrupted),
    (.backgroundStartRefused(code: 0), .needsForeground),
  ]

  @Test("every failure has its reason and its own sentence, bare or under the engine's wrapper")
  func reasons() {
    for (failure, reason) in Self.failures {
      #expect(CaptureFailure.reason(for: failure) == reason)
      #expect(CaptureFailure.reason(for: BlurtError.audioCaptureFailed(underlying: failure)) == reason)
      let sentence = CaptureFailure.sentence(for: failure)
      #expect(sentence == failure.errorDescription)
      #expect(sentence.hasSuffix("."))
      #expect(CaptureFailure.sentence(for: BlurtError.audioCaptureFailed(underlying: failure)) == sentence)
    }
    #expect(Set(Self.failures.map { CaptureFailure.sentence(for: $0.0) }).count == Self.failures.count)
    #expect(ListeningSourceFailure.windowClosed.errorDescription == "The session is off.")
    #expect(ListeningSourceFailure.noInputDevice.errorDescription == "No microphone is available.")
    // The coordinator's comparison still works with associated values about.
    let wrapped = BlurtError.audioCaptureFailed(underlying: ListeningSourceFailure.windowClosed)
    if case .audioCaptureFailed(let underlying) = wrapped {
      #expect(underlying as? ListeningSourceFailure == .windowClosed)
      #expect(underlying as? ListeningSourceFailure != .interrupted(reason: "x"))
    } else {
      Issue.record("not the wrapper")
    }
  }

  @Test("an error the source didn't throw is the microphone being busy, in the engine's words")
  func strangers() {
    #expect(CaptureFailure.reason(for: Stranger()) == .micBusy)
    #expect(CaptureFailure.reason(for: BlurtError.audioCaptureFailed(underlying: Stranger())) == .micBusy)
    #expect(CaptureFailure.reason(for: CancellationError()) == .micBusy)
    #expect(CaptureFailure.sentence(for: Stranger()) == Stranger().localizedDescription)
    let wrapped = BlurtError.audioCaptureFailed(underlying: Stranger())
    #expect(CaptureFailure.sentence(for: wrapped) == Stranger().localizedDescription)
    #expect(!CaptureFailure.sentence(for: wrapped).hasPrefix("Audio capture failed"))
  }

  @Test("an event is a reason when it is a failure, and nothing when it is news")
  func events() {
    #expect(CaptureFailure.reason(for: .interrupted(reason: "audioDeviceInUseByAnotherClient")) == .interrupted)
    #expect(CaptureFailure.reason(for: .runtimeError(code: -12_782)) == .micBusy)
    #expect(CaptureFailure.reason(for: .silent) == .micSilent)
    #expect(CaptureFailure.reason(for: .interruptionEnded) == nil)
    #expect(CaptureFailure.reason(for: .routeChanged(reason: "newDeviceAvailable", input: "BluetoothHFP")) == nil)
  }

  @Test("the session's reasons are named, and an unknown one keeps its number")
  func reasonNames() {
    let busy = AVCaptureSession.InterruptionReason.audioDeviceInUseByAnotherClient
    #expect(WindowedAudioSource.interruptionName(busy.rawValue) == "audioDeviceInUseByAnotherClient")
    let background = AVCaptureSession.InterruptionReason.videoDeviceNotAvailableInBackground
    #expect(WindowedAudioSource.interruptionName(background.rawValue) == "videoDeviceNotAvailableInBackground")
    #expect(WindowedAudioSource.interruptionName(nil) == "unknown")
    #expect(WindowedAudioSource.interruptionName(999) == "reason 999")
    let newDevice = AVAudioSession.RouteChangeReason.newDeviceAvailable
    #expect(WindowedAudioSource.routeChangeName(newDevice.rawValue) == "newDeviceAvailable")
    #expect(WindowedAudioSource.routeChangeName(AVAudioSession.RouteChangeReason.override.rawValue) == "override")
    #expect(WindowedAudioSource.routeChangeName(nil) == "unknown")
    #expect(WindowedAudioSource.routeChangeName(999) == "reason 999")
  }
}

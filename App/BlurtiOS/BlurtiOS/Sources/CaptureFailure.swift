import BlurtEngine
import BlurtiOSCore
import Foundation

/// A capture failure as the keyboard and the home screen say it: the
/// `FailureReason` the keyboard shows a line for and hops with, and one
/// sentence. Every failure the window's source throws has a reason of its
/// own; anything else the engine wraps as `audioCaptureFailed` — its own
/// `MicCaptureError`, a stranger — is the microphone being busy. So the
/// keyboard never sees "Audio capture failed: …" for a policy or system cause.
nonisolated enum CaptureFailure {
  /// The reason for a failed start: `windowClosed` is the session off, a
  /// refused background start wants the foreground, an interruption (or a
  /// session that didn't come back from one) is an interruption, silence is
  /// silence, and the rest — no device, a dead or unconfigurable session,
  /// anything the source didn't throw — is the microphone busy.
  static func reason(for error: any Error) -> FailureReason {
    guard let failure = unwrapped(error) as? ListeningSourceFailure else { return .micBusy }
    return switch failure {
    case .windowClosed: .sessionOff
    case .noInputDevice, .runtimeError, .configureFailed: .micBusy
    case .interrupted, .couldNotResume: .interrupted
    case .inputSilent: .micSilent
    case .backgroundStartRefused: .needsForeground
    }
  }

  /// The failure in its own words — the source's sentence, or the engine's
  /// for an error the source didn't throw.
  static func sentence(for error: any Error) -> String {
    let underlying = unwrapped(error)
    return (underlying as? any LocalizedError)?.errorDescription ?? underlying.localizedDescription
  }

  /// A source event as a reason, or nil for one that is news, not a failure:
  /// an interruption ending, the route changing.
  static func reason(for event: SourceEvent) -> FailureReason? {
    switch event {
    case .interrupted: .interrupted
    case .runtimeError: .micBusy
    case .silent: .micSilent
    case .interruptionEnded, .routeChanged: nil
    }
  }

  /// The error under the engine's `audioCaptureFailed`, or the error itself.
  private static func unwrapped(_ error: any Error) -> any Error {
    if case BlurtError.audioCaptureFailed(let underlying) = error { return underlying }
    return error
  }
}

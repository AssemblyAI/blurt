import AVFoundation
import Foundation

/// What the session and the audio route say while the window is open, each
/// turned into a `SourceEvent` on `events`, one log line (`Capture`, public),
/// and what the next start needs to know: the runtime error's code, the
/// interruption's reason, whether an interruption ended with the session down.
///
/// Registered on the control queue before the first `startRunning`, so a
/// start the session refuses on the spot is explained by what it posted
/// rather than reported as "no microphone". The handlers run on whatever
/// thread posts — the session's own for its three, the audio session's for
/// the route — and so log what they have: the session's flags, never the
/// application state, which is the main actor's.
extension WindowedAudioSource {
  static let unknownReason = "unknown"

  /// Registers the four observers, once.
  func observeSession() {
    guard observers.isEmpty else { return }
    observers = [
      observe(AVCaptureSession.runtimeErrorNotification, from: session) { source, notification in
        source.sessionFailed(code: (notification.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.code ?? 0)
      },
      observe(AVCaptureSession.wasInterruptedNotification, from: session) { source, notification in
        let raw = notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int
        source.sessionInterrupted(reason: Self.interruptionName(raw))
      },
      observe(AVCaptureSession.interruptionEndedNotification, from: session) { source, _ in
        source.sessionInterruptionEnded()
      },
      observe(AVAudioSession.routeChangeNotification, from: AVAudioSession.sharedInstance()) { source, notification in
        let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
        let input = AVAudioSession.sharedInstance().currentRoute.inputs.first?.portType.rawValue
        source.routeChanged(reason: Self.routeChangeName(raw), input: input)
      },
    ]
  }

  /// One observer, weak on the source, run on the posting thread.
  private func observe(
    _ name: Notification.Name, from object: AnyObject,
    _ handle: @escaping @Sendable (WindowedAudioSource, Notification) -> Void
  ) -> any NSObjectProtocol {
    NotificationCenter.default.addObserver(forName: name, object: object, queue: nil) { [weak self] notification in
      guard let self else { return }
      handle(self, notification)
    }
  }

  private func sessionFailed(code: Int) {
    lastRuntimeError.withLock { $0 = code }
    Self.log.error("capture runtimeError code=\(code) \(self.sessionFlags, privacy: .public)")
    eventSink.yield(.runtimeError(code: code))
  }

  private func sessionInterrupted(reason: String) {
    interruption.withLock { $0 = reason }
    Self.log.notice("capture interrupted reason=\(reason, privacy: .public) \(self.sessionFlags, privacy: .public)")
    eventSink.yield(.interrupted(reason: reason))
  }

  /// iOS resumes a session it interrupted while running; one it finds
  /// stopped stays stopped, and a held session down now has to be started
  /// again — that is the resume, and its failure is `couldNotResume`.
  private func sessionInterruptionEnded() {
    interruption.withLock { $0 = nil }
    downAfterInterruption.store(isHeldOpen && !session.isRunning, ordering: .releasing)
    Self.log.notice("capture interruptionEnded \(self.sessionFlags, privacy: .public)")
    eventSink.yield(.interruptionEnded)
  }

  private func routeChanged(reason: String, input: String?) {
    let route = "reason=\(reason) input=\(input ?? "none")"
    Self.log.notice("capture route \(route, privacy: .public) \(self.sessionFlags, privacy: .public)")
    eventSink.yield(.routeChanged(reason: reason, input: input))
  }

  /// The system's name for an interruption reason, or its number for one
  /// this build doesn't know.
  static func interruptionName(_ raw: Int?) -> String {
    guard let raw else { return unknownReason }
    let names: [AVCaptureSession.InterruptionReason: String] = [
      .videoDeviceNotAvailableInBackground: "videoDeviceNotAvailableInBackground",
      .audioDeviceInUseByAnotherClient: "audioDeviceInUseByAnotherClient",
      .videoDeviceInUseByAnotherClient: "videoDeviceInUseByAnotherClient",
      .videoDeviceNotAvailableWithMultipleForegroundApps: "videoDeviceNotAvailableWithMultipleForegroundApps",
      .videoDeviceNotAvailableDueToSystemPressure: "videoDeviceNotAvailableDueToSystemPressure",
    ]
    return AVCaptureSession.InterruptionReason(rawValue: raw).flatMap { names[$0] } ?? "reason \(raw)"
  }

  /// The system's name for a route change reason, or its number.
  static func routeChangeName(_ raw: UInt?) -> String {
    guard let raw else { return unknownReason }
    let names: [AVAudioSession.RouteChangeReason: String] = [
      .unknown: "unknown",
      .newDeviceAvailable: "newDeviceAvailable",
      .oldDeviceUnavailable: "oldDeviceUnavailable",
      .categoryChange: "categoryChange",
      .override: "override",
      .wakeFromSleep: "wakeFromSleep",
      .noSuitableRouteForCategory: "noSuitableRouteForCategory",
      .routeConfigurationChange: "routeConfigurationChange",
    ]
    return AVAudioSession.RouteChangeReason(rawValue: raw).flatMap { names[$0] } ?? "reason \(raw)"
  }
}

import BlurtEngine
import BlurtiOSCore
import Foundation
import UIKit

/// The Typeless layer: a zero-height Picture in Picture window
/// (`PictureInPictureKeeper`) keeps the process in a foreground-like role, so
/// the microphone can park between dictations and still be started from the
/// keyboard's press, and the orange dot is on only while recording.
///
/// The keeper starts while the window opens in front; on `didStart` the source
/// parks and the record says `pip`. If the keeper stops while Blurt is in
/// front (the user closed it), the mic is held again and the record says
/// `held`. If it stops in the background, nothing can start the mic until the
/// next foreground, so that is reported as the source lost: the window waits
/// as it does for an interruption, and on the next foreground it holds the mic
/// again and re-arms the keeper. A parked start iOS refused reaches the window
/// the same way, through the coordinator's capture failure — never a refusal
/// counted, never a window closed over it.
@MainActor
final class PictureInPictureIdle: IdleMode {
  private static let log = HostIdentity.current.logger("ListeningWindow")
  /// Thrown by `windowOpened` where the device has no Picture in Picture.
  struct Unsupported: Error {}

  let kind = ListeningState.Idle.pip
  let keeper = PictureInPictureKeeper()
  var report: ((IdleReport) -> Void)?
  private let appState: () -> UIApplication.State
  private var source: (any ListeningSource)?
  /// The source is parked under the keeper: a press's start needs the keeper alive.
  private var parked = false
  /// The window is closing: the keeper stopping is ours, not the user's.
  private var closing = false

  init(appState: @escaping () -> UIApplication.State) {
    self.appState = appState
    keeper.onStart = { [weak self] in self?.keeperStarted() }
    keeper.onStop = { [weak self] in self?.keeperStopped() }
  }

  /// Held: the source open. Parked: the keeper alive over an open source.
  var isLive: Bool {
    guard let source, source.isOpen else { return false }
    return !parked || keeper.isActive
  }

  func windowOpened(source: any ListeningSource) async throws {
    self.source = source
    closing = false
    guard PictureInPictureKeeper.isSupported else { throw Unsupported() }
    keeper.arm()
    // A resume under a keeper that never stopped gets no `didStart`: the
    // source was just held again, so it parks here instead.
    guard !keeper.isActive else {
      keeperStarted()
      return
    }
    keeper.start()
  }

  func utteranceWillBegin() {}

  func utteranceDidEnd() {}

  func windowClosing() {
    closing = true
    parked = false
    keeper.disarm()
    source = nil
  }

  /// The keeper is up: the mic can close between dictations now.
  private func keeperStarted() {
    guard let source, !closing else { return }
    Task {
      await source.park()
      parked = true
      Self.log.notice("picture in picture up; the mic is parked")
      report?(.idleChanged(.pip))
    }
  }

  /// The keeper closed. In front the mic goes back to being held, so the
  /// window still works; in the background nothing can start it until the
  /// next foreground, which the window waits for.
  private func keeperStopped() {
    guard !closing, let source else { return }
    parked = false
    if appState() == .background {
      Self.log.notice("picture in picture stopped in the background; the mic waits for the next foreground")
      report?(.sourceDied(.needsForeground))
      return
    }
    Task {
      do {
        try await source.hold()
        Self.log.notice("picture in picture stopped in front; the mic is held")
        report?(.idleChanged(.held))
      } catch {
        Self.log.error("picture in picture stopped; hold failed: \(error.localizedDescription, privacy: .public)")
        report?(.sourceDied(CaptureFailure.reason(for: error)))
      }
    }
  }
}

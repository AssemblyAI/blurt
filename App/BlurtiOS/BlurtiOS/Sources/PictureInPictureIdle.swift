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
///
/// Every report names the generation the mode was armed for: the keeper's
/// callbacks land on their own schedule, and the park or hold behind one is
/// awaited, so a report is checked against the window it was made for after
/// every await, and a window closing cancels the work outright.
@MainActor
final class PictureInPictureIdle: IdleMode {
  private static let log = HostIdentity.current.logger("ListeningWindow")
  /// How long a closing window waits for the keeper to stop before the next
  /// window opens under it (DESIGN.md): a hop over an interrupted window
  /// closes this one and opens another at once, and the new window must not
  /// park under a keeper that is on its way out.
  static let keeperStopWait: Duration = .seconds(1)
  /// Thrown by `windowOpened` where the device has no Picture in Picture.
  struct Unsupported: Error {}

  let kind = ListeningState.Idle.pip
  let keeper = PictureInPictureKeeper()
  var report: ((IdleReport, ListeningWindowMachine.Generation) -> Void)?
  private let appState: () -> UIApplication.State
  private var source: (any ListeningSource)?
  /// The window this mode is armed for: what every report carries.
  private var generation: ListeningWindowMachine.Generation = 0
  /// The source is parked under the keeper: a press's start needs the keeper alive.
  private var parked = false
  /// The window is closing: the keeper stopping is ours, not the user's.
  private var closing = false
  /// The park or hold a keeper callback started, so a closing window can
  /// cancel it rather than have it report for the window that follows.
  private var keeperTask: Task<Void, Never>?

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

  func windowOpened(source: any ListeningSource, generation: ListeningWindowMachine.Generation) async throws {
    self.source = source
    self.generation = generation
    closing = false
    guard PictureInPictureKeeper.isSupported else { throw Unsupported() }
    keeper.arm()
    // A resume under a keeper that never stopped gets no `didStart`: the
    // source was just held again, so it parks here instead. One still
    // stopping is not that keeper: its `didStop` is on its way, and the start
    // asked for here runs once it has landed.
    if keeper.isActive, !keeper.isStopping {
      keeperStarted()
      return
    }
    keeper.start()
  }

  func utteranceWillBegin() {}

  func utteranceDidEnd() {}

  /// Lets go of the keeper and waits for it to stop — `keeperStopWait` at
  /// most — so the window that opens next never parks under one on its way out.
  func windowClosing() async {
    closing = true
    parked = false
    keeperTask?.cancel()
    keeperTask = nil
    keeper.disarm()
    source = nil
    await keeper.waitUntilStopped(timeout: Self.keeperStopWait)
  }

  /// The keeper is up: the mic can close between dictations now.
  private func keeperStarted() {
    guard let source, !closing else { return }
    let generation = generation
    keeperTask = Task {
      await source.park()
      guard stillArmed(for: generation) else { return }
      parked = true
      Self.log.notice("picture in picture up; the mic is parked")
      report?(.idleChanged(.pip), generation)
    }
  }

  /// The keeper closed. In front the mic goes back to being held, so the
  /// window still works; in the background nothing can start it until the
  /// next foreground, which the window waits for.
  private func keeperStopped() {
    guard !closing, let source else { return }
    parked = false
    let generation = generation
    if appState() == .background {
      Self.log.notice("picture in picture stopped in the background; the mic waits for the next foreground")
      report?(.sourceDied(.needsForeground), generation)
      return
    }
    keeperTask = Task {
      do {
        try await source.hold()
        guard stillArmed(for: generation) else { return }
        Self.log.notice("picture in picture stopped in front; the mic is held")
        report?(.idleChanged(.held), generation)
      } catch {
        guard stillArmed(for: generation) else { return }
        Self.log.error("picture in picture stopped; hold failed: \(error.localizedDescription, privacy: .public)")
        report?(.sourceDied(CaptureFailure.reason(for: error)), generation)
      }
    }
  }

  /// After an await: the window the work was for is still the one armed, and
  /// not closing. A task cancelled by `windowClosing` fails this too.
  private func stillArmed(for generation: ListeningWindowMachine.Generation) -> Bool {
    !Task.isCancelled && !closing && generation == self.generation
  }
}

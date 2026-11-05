import BlurtEngine
import BlurtiOSCore
import Foundation
import UIKit

/// What the idle mode says back to the window about the microphone between
/// dictations. The window turns each into the machine's event with the
/// generation it is about.
enum IdleReport: Sendable, Equatable {
  /// The mode took hold of the mic between dictations (`pip`), or let go of it (`held`).
  case idleChanged(ListeningState.Idle)
  /// The mic between dictations is lost until the next foreground: a parked
  /// start iOS refused, or the keeper gone in the background. The window
  /// waits as it does for an interruption — never a refusal counted, never a
  /// window closed over it.
  case sourceDied(FailureReason)
}

/// What keeps the microphone closed between dictations, when anything does.
/// `HeldIdle` keeps nothing: the mic stays open for the window, the orange
/// dot with it. `PictureInPictureIdle` parks it under a Picture in Picture
/// keeper. The window calls the hooks at the matching effects, so a mode is
/// a plug: one whose `windowOpened` throws leaves the window held.
@MainActor
protocol IdleMode: AnyObject {
  /// The mode's name for the record; the machine's `idle` follows the reports.
  var kind: ListeningState.Idle { get }
  /// "A press records now", as far as the mode can tell: the source open —
  /// and, once parked, the keeper alive over it.
  var isLive: Bool { get }
  /// Where the mode reports. The window sets it before the first `windowOpened`.
  var report: ((IdleReport) -> Void)? { get set }
  /// The source is open and held: the mode may take over from here.
  func windowOpened(source: any ListeningSource) async throws
  /// A dictation is about to record.
  func utteranceWillBegin()
  /// A dictation ended, however it ended.
  func utteranceDidEnd()
  /// The source is about to close: let go of everything.
  func windowClosing()
}

/// The base: the mic held open for the window, nothing between dictations.
@MainActor
final class HeldIdle: IdleMode {
  let kind = ListeningState.Idle.held
  var report: ((IdleReport) -> Void)?
  private var source: (any ListeningSource)?

  var isLive: Bool { source?.isOpen ?? false }

  func windowOpened(source: any ListeningSource) async throws {
    self.source = source
  }

  func utteranceWillBegin() {}

  func utteranceDidEnd() {}

  func windowClosing() {
    source = nil
  }
}

/// Which mode a window gets.
@MainActor
enum IdleModes {
  /// `-BlurtIdleMode held|pip`: the mode, whatever the device supports; debug builds only.
  static let launchArgument = "BlurtIdleMode"
  private static let log = HostIdentity.current.logger("ListeningWindow")

  /// Picture in Picture where the device supports it, held otherwise — or
  /// what the launch argument says.
  static func production(appState: @escaping () -> UIApplication.State) -> any IdleMode {
    var override: String?
    #if DEBUG
      override = UserDefaults.standard.string(forKey: launchArgument)
    #endif
    let wantsPictureInPicture: Bool =
      switch override {
      case "held": false
      case "pip": true
      default: PictureInPictureKeeper.isSupported
      }
    let mode: any IdleMode = wantsPictureInPicture ? PictureInPictureIdle(appState: appState) : HeldIdle()
    log.notice(
      "idle mode \(mode.kind.rawValue, privacy: .public) (-\(launchArgument, privacy: .public) \(override ?? "unset", privacy: .public); pip supported: \(PictureInPictureKeeper.isSupported))"
    )
    return mode
  }
}

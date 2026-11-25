import BlurtEngine
import BlurtiOSCore
import Foundation
import UIKit

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
      case "held":
        false

      case "pip":
        true

      default:
        PictureInPictureKeeper.isSupported
      }
    let mode: any IdleMode = wantsPictureInPicture ? PictureInPictureIdle(appState: appState) : HeldIdle()
    log.notice(
      "idle mode \(mode.kind.rawValue, privacy: .public) (-\(launchArgument, privacy: .public) \(override ?? "unset", privacy: .public); pip supported: \(PictureInPictureKeeper.isSupported))"
    )
    return mode
  }
}

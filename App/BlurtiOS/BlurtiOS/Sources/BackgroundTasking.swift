import BlurtEngine
import BlurtiOSCore
import Foundation
import UIKit

/// A named stretch of background time: the window asks for one around an
/// interruption, the coordinator around a release, so the words land before
/// iOS suspends the app. A protocol so tests count them instead of asking
/// `UIApplication`.
@MainActor
protocol BackgroundTasking: AnyObject {
  /// Holds a task under `name`; a second ask under the same name keeps the one held.
  func begin(_ name: String)
  /// Ends the task under `name`; nothing held under it is nothing to do.
  func end(_ name: String)
}

/// `UIApplication.beginBackgroundTask`, ended by its owner or by its own
/// timer at `BlurtShared.releaseBackgroundTask` — under the system's own
/// limit, so the task never expires on us with the work half done (DESIGN.md).
/// Should the system call time anyway, the expiration handler ends the task
/// before it returns: UIKit runs the handler on the main thread and requires
/// the task ended inside it, and a hop to a later turn is a task left open
/// past its expiry, which iOS kills the process for.
@MainActor
final class SystemBackgroundTasks: BackgroundTasking {
  private static let log = HostIdentity.current.logger("ListeningWindow")
  static let limit: TimeInterval = BlurtShared.releaseBackgroundTask

  private struct Held {
    let id: UIBackgroundTaskIdentifier
    let timer: Task<Void, Never>
  }

  private var held: [String: Held] = [:]

  func begin(_ name: String) {
    guard held[name] == nil else { return }
    let id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
      // The handler is main-actor by UIKit's own annotation: synchronous, on this turn.
      Self.log.notice("background task \(name, privacy: .public) expiring")
      self?.end(name)
    }
    guard id != .invalid else {
      Self.log.error("background task \(name, privacy: .public) refused")
      return
    }
    let timer = Task { [weak self] in
      try? await Task.sleep(for: .seconds(Self.limit))
      guard !Task.isCancelled else { return }
      self?.end(name)
    }
    held[name] = Held(id: id, timer: timer)
    Self.log.notice("background task \(name, privacy: .public) begun")
  }

  func end(_ name: String) {
    guard let task = held.removeValue(forKey: name) else { return }
    task.timer.cancel()
    UIApplication.shared.endBackgroundTask(task.id)
    Self.log.notice("background task \(name, privacy: .public) ended")
  }
}

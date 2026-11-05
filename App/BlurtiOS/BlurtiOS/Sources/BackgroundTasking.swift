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
      Task { @MainActor in self?.end(name) }
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

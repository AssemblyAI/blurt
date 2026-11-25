import BlurtEngine
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

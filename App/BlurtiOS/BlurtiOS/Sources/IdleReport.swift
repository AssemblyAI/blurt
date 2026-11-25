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

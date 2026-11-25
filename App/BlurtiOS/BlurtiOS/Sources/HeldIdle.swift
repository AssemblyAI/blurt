import BlurtEngine
import BlurtiOSCore
import Foundation
import UIKit

/// The base: the mic held open for the window, nothing between dictations.
@MainActor
final class HeldIdle: IdleMode {
  let kind = ListeningState.Idle.held
  var report: ((IdleReport, ListeningWindowMachine.Generation) -> Void)?
  private var source: (any ListeningSource)?

  var isLive: Bool { source?.isOpen ?? false }

  func windowOpened(source: any ListeningSource, generation _: ListeningWindowMachine.Generation) {
    self.source = source
  }

  func utteranceWillBegin() {
    // Nothing to do: the held mic stays open across utterances.
  }

  func utteranceDidEnd() {
    // Nothing to do: the held mic stays open across utterances.
  }

  func windowClosing() {
    source = nil
  }
}

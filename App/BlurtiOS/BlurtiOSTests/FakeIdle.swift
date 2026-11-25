import BlurtEngine
import Foundation
import Synchronization
import UIKit

@testable import BlurtiOS
@testable import BlurtiOSCore

/// A held idle mode that counts its hooks, keeps the source and the
/// generation it was given, and takes `closingDelay` to let go — as a keeper
/// on its way out would.
@MainActor
final class FakeIdle: IdleMode {
  let kind = ListeningState.Idle.held
  var report: ((IdleReport, ListeningWindowMachine.Generation) -> Void)?
  private(set) var opened = 0
  private(set) var closing = 0
  /// `windowClosing` calls that have returned.
  private(set) var closed = 0
  private(set) var began = 0
  private(set) var ended = 0
  /// The window this mode was last armed for.
  private(set) var generation: ListeningWindowMachine.Generation = 0
  private let closingDelay: Duration
  private let ledger: Ledger
  private var source: (any ListeningSource)?

  var isLive: Bool { source?.isOpen ?? false }

  init(closingDelay: Duration = .zero, ledger: Ledger = Ledger()) {
    self.closingDelay = closingDelay
    self.ledger = ledger
  }

  func windowOpened(source: any ListeningSource, generation: ListeningWindowMachine.Generation) {
    self.source = source
    self.generation = generation
    opened += 1
  }

  func utteranceWillBegin() { began += 1 }

  func utteranceDidEnd() { ended += 1 }

  func windowClosing() async {
    closing += 1
    ledger.note("idle.closing")
    source = nil
    if closingDelay > .zero { try? await Task.sleep(for: closingDelay) }
    closed += 1
    ledger.note("idle.closed")
  }
}

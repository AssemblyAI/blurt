@testable import BlurtiOS
@testable import BlurtiOSCore

/// A held idle mode that counts its hooks, keeps the source and the
/// generation it was given, and with `holdsClosing` lets go only on
/// `releaseClosing()` — as a keeper on its way out would, for as long as the
/// test needs to see what the window does meanwhile.
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
  private let holdsClosing: Bool
  private let closingHold = Hold()
  private let ledger: Ledger
  private var source: (any ListeningSource)?

  var isLive: Bool { source?.isOpen ?? false }
  /// Whether a held `windowClosing` is parked: the mode is letting go.
  var isClosing: Bool { closingHold.isHolding }

  init(holdsClosing: Bool = false, ledger: Ledger = Ledger()) {
    self.holdsClosing = holdsClosing
    self.ledger = ledger
  }

  func windowOpened(source: any ListeningSource, generation: ListeningWindowMachine.Generation) {
    self.source = source
    self.generation = generation
    opened += 1
  }

  /// Lets a held `windowClosing` finish, now or whenever it gets there.
  func releaseClosing() { closingHold.release() }

  func utteranceWillBegin() { began += 1 }

  func utteranceDidEnd() { ended += 1 }

  func windowClosing() async {
    closing += 1
    ledger.note("idle.closing")
    source = nil
    if holdsClosing { await closingHold.wait() }
    closed += 1
    ledger.note("idle.closed")
  }
}

import Foundation
import Testing

@testable import BlurtEngine

/// Injector stub that honors task cancellation (like the real `KeyInjector`) and
/// blocks inside `insert` until released, so a `cancel()` can be landed while the
/// session is suspended in `.injecting`. Gate choreography lives in `Gate`.
actor GatedInjector: InjectorProtocol {
  /// Fired each time a paste is actually recorded — lets a test assert, via
  /// `confirmation(expectedCount: 0)`, that a cancelled injection records nothing.
  private let onRecord: @Sendable () -> Void

  /// When false, `insert` skips its cancellation check and returns normally on a
  /// cancelled task — modeling the real injector's final, non-cancellable
  /// stretch after its last `checkCancellation` (the paste already landed).
  private let honorsCancellation: Bool
  private let gate = Gate()

  init(
    honorsCancellation: Bool = true,
    onRecord: @escaping @Sendable () -> Void = {
      // Nothing to observe unless the test passes its own hook.
    }
  ) {
    self.honorsCancellation = honorsCancellation
    self.onRecord = onRecord
  }

  func setTarget(_: CapturedFocus?) {
    // The gate doesn't model a target: every insert goes through it.
  }

  func insert(_: String, after _: String?, windowTitle _: String?, security _: TargetSecurity) async throws {
    await gate.enter()
    if honorsCancellation { try Task.checkCancellation() }
    onRecord()
  }

  func waitUntilInsertEntered() async { await gate.waitUntilEntered() }
  func allowInsertToFinish() { gate.allowToFinish() }
}

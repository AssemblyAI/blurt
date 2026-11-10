@testable import BlurtEngine

/// The router with every key under one mode — the shape the router suites were
/// written against, before each key had its own. Test-only: production always
/// binds per key (`DictationKeyRouter.init(activations:)`).
extension DictationKeyRouter {
  init(
    triggerKeyCodes: Set<Int>, holdThreshold: Duration = .seconds(1), activation: TriggerActivation = .tapOrHold,
    escapeCancels: @escaping @Sendable () -> Bool = { false }
  ) {
    self.init(
      activations: Dictionary(uniqueKeysWithValues: triggerKeyCodes.map { ($0, activation) }),
      holdThreshold: holdThreshold, escapeCancels: escapeCancels)
  }

  @discardableResult
  mutating func rebind(triggerKeyCodes: Set<Int>, activation: TriggerActivation) -> Bool {
    rebind(activations: Dictionary(uniqueKeysWithValues: triggerKeyCodes.map { ($0, activation) }))
  }

  /// The keycodes the router watches.
  var triggerKeyCodes: Set<Int> { Set(activations.keys) }
}

extension DictationKeyRouter.Event {
  /// `keyCode`'s modifier going down, or coming up.
  static func down(_ keyCode: Int) -> Self { .flagsChanged(keyCode: keyCode, triggerFlagIsOn: true) }
  static func up(_ keyCode: Int) -> Self { .flagsChanged(keyCode: keyCode, triggerFlagIsOn: false) }
}

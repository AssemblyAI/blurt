import Foundation
import Testing

@testable import BlurtEngine

/// The activation mode's decode rule, store round-trip, and the Shortcut
/// section's copy. The latch decisions themselves are scenario-tested where they
/// act, in `DictationKeyGateTests`.
@Suite("TriggerActivation")
struct TriggerActivationTests {
  @Test("defaults to tap-or-hold when unset")
  func defaultsToTapOrHold() {
    // The shipped behavior: an install that never touched the picker must keep
    // both gestures working.
    #expect(TriggerActivationStore(defaults: freshDefaults()).activation == .tapOrHold)
    #expect(TriggerActivation.fromPersisted("") == .tapOrHold)
  }

  @Test("persists and reads back a chosen mode")
  func roundTrips() {
    let defaults = freshDefaults()
    let store = TriggerActivationStore(defaults: defaults)
    store.activation = .hold
    #expect(TriggerActivationStore(defaults: defaults).activation == .hold)
  }

  @Test("an unknown stored value falls back to the default")
  func unknownFallsBack() {
    let defaults = freshDefaults()
    defaults.set("DoubleTap", forKey: TriggerActivationStore.defaultsKey)
    #expect(TriggerActivationStore(defaults: defaults).activation == .tapOrHold)
  }

  @Test("every mode names itself and explains itself, distinctly")
  func copyIsDistinctPerMode() {
    // The picker titles and the footer sentence under it: each mode must read
    // differently, or the picker offers two spellings of one behavior.
    #expect(Set(TriggerActivation.allCases.map(\.label)).count == TriggerActivation.allCases.count)
    #expect(
      Set(TriggerActivation.allCases.map(\.guidance)).count == TriggerActivation.allCases.count)
    // The default's footer is the sentence that shipped before the picker
    // existed — the unset experience must not reword itself.
    #expect(
      TriggerActivation.tapOrHold.guidance
        == "Tap to start and tap again to stop, or hold the key and release to dictate.")
  }
}

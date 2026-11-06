import Foundation
import Testing

@testable import BlurtEngine

/// The activation mode's decode rule, store round-trip, and the Shortcut
/// section's copy. The latch decisions themselves are scenario-tested where they
/// act, in `DictationKeyGateTests`.
@Suite("TriggerActivation")
struct TriggerActivationTests {
  /// The one mode every key is pressed under.
  private func sharedMode(_ defaults: UserDefaults) -> TriggerActivation {
    TriggerKeyBindings(defaults: defaults).activation
  }

  @Test("defaults to tap-or-hold when unset")
  func defaultsToTapOrHold() {
    // The shipped behavior: an install that never touched the picker must keep
    // both gestures working.
    #expect(sharedMode(freshDefaults()) == .tapOrHold)
    #expect(TriggerActivation.fromPersisted("") == .tapOrHold)
  }

  @Test("a mode set is the mode read")
  func roundTrips() {
    let defaults = freshDefaults()
    TriggerActivationStore(defaults: defaults).setActivation(.hold)
    #expect(sharedMode(defaults) == .hold)
  }

  @Test("an unknown stored value falls back to the default")
  func unknownFallsBack() {
    let defaults = freshDefaults()
    defaults.set("DoubleTap", forKey: TriggerActivationStore.defaultsKey)
    #expect(sharedMode(defaults) == .tapOrHold)
  }

  @Test("every mode names itself and explains itself, distinctly")
  func copyIsDistinctPerMode() {
    // The picker titles and the footer sentence under it: each mode must read
    // differently, or the picker offers two spellings of one behavior.
    #expect(Set(TriggerActivation.allCases.map(\.label)).count == TriggerActivation.allCases.count)
    #expect(
      Set(TriggerActivation.allCases.map { $0.hint(for: .dictate) }).count == TriggerActivation.allCases.count)
    #expect(TriggerActivation.tapOrHold.hint(for: .dictate) == "Tap to start and stop. Hold to talk.")
    #expect(TriggerActivation.hold.hint(for: .readAloud) == "Hold to listen. Release to stop.")
    #expect(TriggerActivation.tapOrHold.hint(for: .ask) == "Tap to start and stop. Hold to ask.")
  }

  @Test func mainWindowWordingNamesOnlyTheConfiguredGestures() {
    // The ready screen must not tell a hold-only user to tap, or a tap-only
    // user to release — each gesture it names has to actually work.
    #expect(TriggerActivation.tapOrHold.startVerb == "tap")
    #expect(TriggerActivation.tap.startVerb == "tap")
    #expect(TriggerActivation.hold.startVerb == "hold")
  }
}

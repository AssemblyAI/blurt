import Foundation
import Testing

@testable import BlurtEngine

/// The pill's dragged-origin persistence. Engine-side (rather than private to the
/// AppKit controller) so it lands in `PersistedSettings.allDefaultsKeys` and so
/// these rules are covered by `swift test` at all.
@Suite("OverlayOriginStore")
struct OverlayOriginStoreTests {
  @Test("unset reads as nil, so the default placement is used")
  func unsetIsNil() {
    let store = OverlayOriginStore(defaults: freshDefaults())
    #expect(store.origin == nil)
  }

  @Test("round-trips a dragged origin")
  func roundTrips() {
    let store = OverlayOriginStore(defaults: freshDefaults())
    store.origin = CGPoint(x: 120.5, y: 340.25)
    #expect(store.origin == CGPoint(x: 120.5, y: 340.25))
  }

  @Test("a half-written pair reads as nil rather than an implied zero")
  func halfWrittenIsNil() {
    // `double(forKey:)` reports 0 for a missing key, so keying off the values
    // alone would place the pill at an origin the user never chose. Both
    // components must be present.
    let xOnly = freshDefaults()
    xOnly.set(120.0, forKey: OverlayOriginStore.xDefaultsKey)
    #expect(OverlayOriginStore(defaults: xOnly).origin == nil)
    // Both directions, since the getter checks the two keys independently: with
    // only one of the presence checks left, a half-written pair still reads as nil
    // in the case that *is* covered while the mirror case places the pill at an
    // implied x of 0 — hard against the left edge of the screen.
    let yOnly = freshDefaults()
    yOnly.set(340.0, forKey: OverlayOriginStore.yDefaultsKey)
    #expect(OverlayOriginStore(defaults: yOnly).origin == nil)
  }

  @Test("nil clears both keys")
  func nilClears() {
    let defaults = freshDefaults()
    let store = OverlayOriginStore(defaults: defaults)
    store.origin = CGPoint(x: 10, y: 20)
    store.origin = nil
    #expect(store.origin == nil)
    #expect(defaults.object(forKey: OverlayOriginStore.xDefaultsKey) == nil)
    #expect(defaults.object(forKey: OverlayOriginStore.yDefaultsKey) == nil)
  }

  // Roster membership for both keys is asserted in `PersistedSettingsTests`,
  // alongside the count that pins the roster as a whole.
}

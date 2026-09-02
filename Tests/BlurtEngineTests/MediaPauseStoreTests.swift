import Foundation
import Testing

@testable import BlurtEngine

@Suite("MediaPauseStore")
struct MediaPauseStoreTests {
  @Test("defaults to off when unset")
  func defaultsToOff() {
    // Controlling other apps is strictly opt-in — an unset key must read as
    // off, so an install that never touched the toggle never queries a player.
    #expect(!MediaPauseStore(defaults: freshDefaults()).isEnabled)
  }

  /// The store is read-only, so what it has to agree with is the slot the Settings
  /// toggle writes through `@AppStorage` — which is what this seeds, rather than a
  /// setter no production code calls.
  @Test("reads back the switch the Settings toggle writes")
  func readsBackTheToggledSlot() {
    let defaults = freshDefaults()
    let store = MediaPauseStore(defaults: defaults)
    defaults.set(true, forKey: MediaPauseStore.defaultsKey)
    #expect(store.isEnabled)
    // Same instance: the store reads through to `defaults` on every access rather
    // than snapshotting at init, so `MediaPauser` picks a Settings change up on
    // the very next dictation.
    defaults.set(false, forKey: MediaPauseStore.defaultsKey)
    #expect(!store.isEnabled)
  }
}

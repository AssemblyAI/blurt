import Foundation
import Testing

@testable import BlurtEngine

@Suite("AudioDuckStore")
struct AudioDuckStoreTests {
  @Test("defaults to off when unset")
  func defaultsToOff() {
    // Changing the system volume is strictly opt-in — an unset key must read as
    // off, so an install that never touched the toggle never moves it.
    #expect(!AudioDuckStore(defaults: freshDefaults()).isEnabled)
  }

  /// The switch is read-only, so what it has to agree with is the slot the
  /// Settings toggle writes through `@AppStorage` — which is what this seeds,
  /// rather than a setter no production code calls.
  @Test("reads back the switch the Settings toggle writes")
  func readsBackTheToggledSlot() {
    let defaults = freshDefaults()
    let store = AudioDuckStore(defaults: defaults)
    defaults.set(true, forKey: AudioDuckStore.defaultsKey)
    #expect(store.isEnabled)
    // Same instance: the store reads through to `defaults` on every access rather
    // than snapshotting at init, so `AudioDucker` picks a Settings change up on
    // the very next dictation.
    defaults.set(false, forKey: AudioDuckStore.defaultsKey)
    #expect(!store.isEnabled)
  }

  @Test("the crash-recovery slot round-trips and clears")
  func pendingRestoreRoundTrips() {
    let defaults = freshDefaults()
    let store = AudioDuckStore(defaults: defaults)
    // Unset means "no duck in flight" — the ducker's every-terminal-render
    // probe must be a no-op on a clean install.
    #expect(store.pendingRestore == nil)
    let pending = AudioDucker.PendingRestore(saved: 0.75, ducked: 0.15)
    store.pendingRestore = pending
    // A second instance over the same defaults sees the slot: this is the
    // "next launch after a crash" read, the reason the slot is persisted at all.
    #expect(AudioDuckStore(defaults: defaults).pendingRestore == pending)
    store.pendingRestore = nil
    #expect(store.pendingRestore == nil)
  }

  @Test("volumes survive the Float→Double→Float round-trip within the tolerance")
  func volumesSurviveTheRoundTrip() throws {
    let store = AudioDuckStore(defaults: freshDefaults())
    // A value with no exact binary representation — the worst case for the
    // restore's equality check against what was persisted.
    let pending = AudioDucker.PendingRestore(saved: 0.7, ducked: 0.7 * AudioDucker.duckFraction)
    store.pendingRestore = pending
    let read = try #require(store.pendingRestore)
    #expect(abs(read.saved - pending.saved) < AudioDucker.volumeTolerance)
    #expect(abs(read.ducked - pending.ducked) < AudioDucker.volumeTolerance)
  }
}

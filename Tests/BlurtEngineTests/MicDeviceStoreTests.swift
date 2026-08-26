import Foundation
import Testing

@testable import BlurtEngine

/// The pure half of microphone selection: the persisted-slot decode shared by
/// the store and the Settings picker, the store's round trip, and the
/// missing-device fallback the capture path applies per press.
@Suite("MicDeviceStore")
struct MicDeviceStoreTests {
  @Test("unset reads as same-as-system")
  func unsetReadsAsSystemDefault() {
    let store = MicDeviceStore(defaults: freshDefaults())
    #expect(store.selection == .systemDefault)
  }

  @Test("the empty string is same-as-system, anything else is a pin")
  func fromPersistedDecodesEmptyAsSystemDefault() {
    // The empty string is also what an unset key reads back as, so the decode
    // rule gives the untouched install exactly one meaning.
    #expect(MicDeviceSelection.fromPersisted("") == .systemDefault)
    #expect(MicDeviceSelection.fromPersisted("uid:built-in") == .pinned(uid: "uid:built-in"))
  }

  @Test("a pinned selection round-trips through the store")
  func pinRoundTrips() {
    let defaults = freshDefaults()
    let store = MicDeviceStore(defaults: defaults)

    store.selection = .pinned(uid: "AppleUSBAudioEngine:test")
    #expect(store.selection == .pinned(uid: "AppleUSBAudioEngine:test"))
    // The on-disk shape is the bare UID string — the contract the Settings
    // picker's `@AppStorage` observation reads.
    #expect(defaults.string(forKey: MicDeviceStore.defaultsKey) == "AppleUSBAudioEngine:test")
  }

  @Test("selecting same-as-system overwrites a stored pin")
  func systemDefaultOverwritesPin() {
    let store = MicDeviceStore(defaults: freshDefaults())
    store.selection = .pinned(uid: "uid:external")

    store.selection = .systemDefault
    #expect(store.selection == .systemDefault)
  }

  @Test("a pinned device that disappeared falls back to the system default")
  func missingPinFallsBack() {
    // The graceful degradation: unplugging the pinned mic must degrade the next
    // press to the system default, never fail it — while the pin itself stays
    // stored (`effective` is per-capture; nothing rewrites the slot).
    let pinned = MicDeviceSelection.pinned(uid: "uid:gone")
    #expect(pinned.effective(pinnedDevicePresent: false) == .systemDefault)
    #expect(pinned.effective(pinnedDevicePresent: true) == pinned)
  }

  @Test("same-as-system is unaffected by device presence")
  func systemDefaultIsStableUnderEffective() {
    #expect(MicDeviceSelection.systemDefault.effective(pinnedDevicePresent: true) == .systemDefault)
    #expect(
      MicDeviceSelection.systemDefault.effective(pinnedDevicePresent: false) == .systemDefault)
  }
}

import Foundation
import Testing

@testable import BlurtEngine

@Suite("SoundPackStore")
struct SoundPackStoreTests {
  private static let brass = SoundPack(id: "rom1a-0", label: "Brass 1", group: "DX7")
  private static let clav = SoundPack(id: "rom1a-19", label: "Clav 1", group: "DX7")

  /// A fixture rather than Blurt's 192 voices: the store's job is the persistence
  /// round trip and the decode-with-default, and the engine no longer ships a
  /// catalog to borrow.
  private static let catalog = SoundPackCatalog(
    voices: [brass, clav], defaultVoiceID: "rom1a-0")

  @Test("defaults to the catalog's default voice when unset")
  func defaultsToCatalogDefault() {
    let store = SoundPackStore(catalog: Self.catalog, defaults: freshDefaults())
    #expect(store.soundPack == Self.brass)
  }

  @Test("persists and reads back a chosen pack")
  func roundTrips() {
    let defaults = freshDefaults()
    SoundPackStore(catalog: Self.catalog, defaults: defaults).soundPack = Self.clav
    #expect(SoundPackStore(catalog: Self.catalog, defaults: defaults).soundPack == Self.clav)
  }

  @Test("none is a storable, distinct value")
  func storesNone() {
    let defaults = freshDefaults()
    SoundPackStore(catalog: Self.catalog, defaults: defaults).soundPack = .none
    #expect(SoundPackStore(catalog: Self.catalog, defaults: defaults).soundPack == .none)
  }

  @Test("an unknown stored value falls back to the default")
  func unknownFallsBack() {
    let defaults = freshDefaults()
    defaults.set("trombone", forKey: SoundPackStore.defaultsKey)
    #expect(SoundPackStore(catalog: Self.catalog, defaults: defaults).soundPack == Self.brass)
  }

  @Test("the key is the roster's, so a reset clears the choice")
  func usesTheRosterKey() {
    // The store stayed engine-side when the catalog left precisely so its key
    // remains a `DefaultsKey` case; `PersistedSettingsTests` pins the rest.
    #expect(SoundPackStore.defaultsKey == DefaultsKey.soundPack.key)
  }
}

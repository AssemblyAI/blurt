import Foundation
import Testing

@testable import BlurtEngine

@Suite("SoundPackStore")
struct SoundPackStoreTests {
  private func freshDefaults() -> UserDefaults {
    let name = "SoundPackStoreTests-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
  }

  @Test("defaults to ORCHESTRA when unset")
  func defaultsToOrchestra() {
    let store = SoundPackStore(defaults: freshDefaults())
    #expect(store.soundPack == .defaultPack)
    #expect(store.soundPack.id == "rom1a-6")
  }

  @Test("persists and reads back a chosen pack")
  func roundTrips() {
    let defaults = freshDefaults()
    let store = SoundPackStore(defaults: defaults)
    let clav = SoundPack.find(id: "rom1a-19")!
    store.soundPack = clav
    #expect(SoundPackStore(defaults: defaults).soundPack == clav)
  }

  @Test("none is a storable, distinct value")
  func storesNone() {
    let defaults = freshDefaults()
    SoundPackStore(defaults: defaults).soundPack = .none
    #expect(SoundPackStore(defaults: defaults).soundPack == .none)
  }

  @Test("an unknown stored value falls back to the default")
  func unknownFallsBack() {
    let defaults = freshDefaults()
    defaults.set("trombone", forKey: "BlurtSoundPack")
    #expect(SoundPackStore(defaults: defaults).soundPack == .defaultPack)
  }
}

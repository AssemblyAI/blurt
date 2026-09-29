import Foundation
import Testing

@testable import BlurtEngine

/// The version the What's New sheet last dealt with. Round-tripping is the whole
/// job; what matters beyond it is that "never recorded" stays distinguishable
/// from a version, since the launch decision treats the two differently.
@Suite("LastSeenVersionStore")
struct LastSeenVersionStoreTests {
  @Test("an unset store has seen no version")
  func unsetIsNil() {
    #expect(LastSeenVersionStore(defaults: freshDefaults()).lastSeen == nil)
  }

  @Test("a version round-trips, and clearing it returns to never-recorded")
  func roundTrips() throws {
    let store = LastSeenVersionStore(defaults: freshDefaults())
    let version = try #require(SemanticVersion("0.1.57"))
    store.lastSeen = version
    #expect(store.lastSeen == version)
    store.lastSeen = nil
    #expect(store.lastSeen == nil)
  }

  @Test("a stored value that isn't a version reads as never recorded")
  func garbageIsNil() {
    let defaults = freshDefaults()
    defaults.set("not a version", forKey: LastSeenVersionStore.defaultsKey)
    #expect(LastSeenVersionStore(defaults: defaults).lastSeen == nil)
  }
}

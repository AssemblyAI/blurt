import Foundation
import Testing

@testable import BlurtEngine

/// The timestamp behind the launch check's daily throttle. Round-tripping is the
/// whole job, but "never checked" has to stay distinguishable from "checked at
/// the reference date" — `double(forKey:)` reports 0 for a missing key, so the
/// store probes `object(forKey:)` first.
@Suite("LastUpdateCheckStore")
struct LastUpdateCheckStoreTests {
  @Test("an unset store reports no previous check")
  func unsetIsNil() {
    let store = LastUpdateCheckStore(defaults: freshDefaults())
    #expect(store.lastCheck == nil)
  }

  @Test("a stamp round-trips")
  func roundTrips() {
    let store = LastUpdateCheckStore(defaults: freshDefaults())
    let when = Date(timeIntervalSinceReferenceDate: 800_000_000)
    store.lastCheck = when
    #expect(store.lastCheck == when)
  }

  @Test("the reference date is a real stamp, not an unset store")
  func referenceDateIsNotNil() {
    // The 0 `double(forKey:)` would report for a missing key. Storing it must
    // still read back as a value, or "never checked" and "checked in 2001"
    // would be the same answer.
    let store = LastUpdateCheckStore(defaults: freshDefaults())
    store.lastCheck = Date(timeIntervalSinceReferenceDate: 0)
    #expect(store.lastCheck == Date(timeIntervalSinceReferenceDate: 0))
  }

  @Test("clearing the stamp returns the store to never-checked")
  func clearing() {
    let store = LastUpdateCheckStore(defaults: freshDefaults())
    store.lastCheck = Date(timeIntervalSinceReferenceDate: 800_000_000)
    store.lastCheck = nil
    #expect(store.lastCheck == nil)
  }

  @Test("the stamp drives the launch gate end to end")
  func feedsTheGate() {
    // The pair as the app uses it: a fresh install checks, and a check just
    // recorded suppresses the next launch's.
    let store = LastUpdateCheckStore(defaults: freshDefaults())
    let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    #expect(AutomaticUpdateCheck.shouldRun(isConfigured: true, lastCheck: store.lastCheck, now: now))
    store.lastCheck = now
    #expect(!AutomaticUpdateCheck.shouldRun(isConfigured: true, lastCheck: store.lastCheck, now: now))
  }
}

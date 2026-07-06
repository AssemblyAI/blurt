import Foundation
import Testing

@testable import BlurtEngine

@Suite("RecentDictations")
struct RecentDictationsTests {
  private let epoch = Date(timeIntervalSinceReferenceDate: 0)

  @Test("records newest-first")
  func newestFirst() {
    var recent = RecentDictations()
    recent.record("one", at: epoch)
    recent.record("two", at: epoch.addingTimeInterval(1))
    #expect(recent.entries.map(\.text) == ["two", "one"])
  }

  @Test("caps at capacity, dropping the oldest")
  func capsAtCapacity() {
    var recent = RecentDictations()
    for (offset, text) in ["a", "b", "c", "d", "e"].enumerated() {
      recent.record(text, at: epoch.addingTimeInterval(Double(offset)))
    }
    #expect(recent.entries.count == RecentDictations.capacity)
    #expect(recent.entries.map(\.text) == ["e", "d", "c"])
  }

  @Test("entries keep a stable, unique id as newer ones push in")
  func stableUniqueIDs() {
    var recent = RecentDictations()
    recent.record("first", at: epoch)
    let firstID = recent.entries[0].id
    recent.record("second", at: epoch.addingTimeInterval(1))

    // The original entry kept the id it was assigned...
    #expect(recent.entries.first { $0.text == "first" }?.id == firstID)
    // ...the newer one got a different id...
    #expect(recent.entries[0].id != firstID)
    // ...and all ids are distinct.
    #expect(Set(recent.entries.map(\.id)).count == recent.entries.count)
  }

  @Test("preserves the timestamp it was recorded with")
  func preservesTimestamp() {
    var recent = RecentDictations()
    let when = Date(timeIntervalSinceReferenceDate: 12345)
    recent.record("hi", at: when)
    #expect(recent.entries[0].timestamp == when)
  }
}

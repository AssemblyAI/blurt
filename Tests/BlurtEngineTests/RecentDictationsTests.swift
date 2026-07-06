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

/// The Recent row's relative timestamp: "just now" for the first minute, then
/// the system's full relative phrasing. `now` and `locale` are injected so the
/// wording is deterministic.
@Suite("RecentDictations.Entry.relativeLabel")
struct RecentDictationsRelativeLabelTests {
  private let english = Locale(identifier: "en_US")

  private func entry(at time: Date) -> RecentDictations.Entry {
    var recent = RecentDictations()
    recent.record("hi", at: time)
    return recent.entries[0]
  }

  @Test("the first minute reads as \"just now\"")
  func justNowUnderAMinute() {
    // The system formatter's bare "in 0 seconds" reads oddly for a dictation
    // that just landed.
    let recorded = Date(timeIntervalSinceReferenceDate: 0)
    let label = entry(at: recorded).relativeLabel(now: recorded + 59, locale: english)
    #expect(label == "just now")
  }

  @Test("small clock skew (entry slightly in the future) still reads as \"just now\"")
  func futureSkewReadsJustNow() {
    let recorded = Date(timeIntervalSinceReferenceDate: 0)
    let label = entry(at: recorded).relativeLabel(now: recorded - 5, locale: english)
    #expect(label == "just now")
  }

  @Test("from one minute on, the full relative phrasing takes over")
  func fullPhrasingAfterAMinute() {
    let recorded = Date(timeIntervalSinceReferenceDate: 0)
    let entry = entry(at: recorded)
    #expect(entry.relativeLabel(now: recorded + 60, locale: english) == "1 minute ago")
    #expect(entry.relativeLabel(now: recorded + 120, locale: english) == "2 minutes ago")
  }
}

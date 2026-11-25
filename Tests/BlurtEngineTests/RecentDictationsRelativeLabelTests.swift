import Foundation
import Testing

@testable import BlurtEngine

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

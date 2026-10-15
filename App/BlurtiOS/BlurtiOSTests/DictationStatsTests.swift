import Foundation
import Testing

@testable import BlurtiOSCore

@Suite("Dictation stats")
struct DictationStatsTests {
  private func scratchDefaults() throws -> UserDefaults {
    let name = "DictationStatsTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defaults.removePersistentDomain(forName: name)
    return defaults
  }

  @Test("a dictation adds one, its words, and the time spoken; empty text adds nothing")
  func records() {
    var stats = DictationStats()
    stats.record("Hello there, world.", spokenFor: 2)
    stats.record("   ", spokenFor: 5)
    #expect(stats.dictations == 1)
    #expect(stats.words == 3)
    #expect(stats.secondsSpoken == 2)
  }

  @Test("words are linguistic words, not whitespace runs")
  func wordCount() {
    #expect(DictationStats.wordCount(of: "Well — don't stop, okay?") == 4)
    #expect(DictationStats.wordCount(of: "") == 0)
  }

  @Test("time saved is the typing time at the speed, less the time spent talking, never negative")
  func timeSaved() {
    var stats = DictationStats()
    stats.record(Array(repeating: "word", count: 72).joined(separator: " "), spokenFor: 30)
    // 72 words at 36 wpm is two minutes of typing; half a minute was spent talking.
    #expect(stats.timeSaved() == .seconds(90))
    #expect(stats.timeSaved(typingWordsPerMinute: 1_000) == .zero)
    #expect(stats.timeSaved(typingWordsPerMinute: 0) == .zero)
  }

  @Test("totals persist, accumulate across dictations, and reset to nothing")
  func persists() throws {
    let defaults = try scratchDefaults()
    #expect(DictationStats.load(from: defaults) == DictationStats())
    DictationStats.record("one two", spokenFor: 1, in: defaults)
    DictationStats.record("three", spokenFor: 1, in: defaults)
    let loaded = DictationStats.load(from: defaults)
    #expect(loaded.dictations == 2)
    #expect(loaded.words == 3)
    DictationStats.reset(in: defaults)
    #expect(DictationStats.load(from: defaults) == DictationStats())
    #expect(DictationStats.decode(Data("not json".utf8)) == DictationStats())
  }

  @Test("counts compact past four digits; durations read largest unit first, skipping zeros")
  func formats() {
    #expect(StatFormat.count(9_999) == 9_999.formatted())
    #expect(StatFormat.count(12_000) == 12_000.formatted(.number.notation(.compactName)))
    #expect(StatFormat.durationParts(.zero).map(\.unit) == ["sec"])
    let parts = StatFormat.durationParts(.seconds(3_600 + 25 * 60 + 45))
    #expect(parts.map(\.value) == ["1", "25", "45"])
    #expect(parts.map(\.unit) == ["hr", "min", "sec"])
    #expect(StatFormat.durationParts(.seconds(86_400 + 5)).map(\.unit) == ["day", "sec"])
  }
}

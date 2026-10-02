import Foundation
import Testing

@testable import BlurtiOSCore

@Suite("Easter egg typing sprint")
struct TypingTestTests {
  private func scratchDefaults() throws -> UserDefaults {
    let name = "TypingTestTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defaults.removePersistentDomain(forName: name)
    return defaults
  }

  @Test("only right words score, five characters to a word with its space; accuracy counts every word")
  func scoring() {
    var test = TypingTest(words: ["hello", "there", "world"])
    #expect(test.isOnTrack("hel"))
    #expect(!test.isOnTrack("hex"))
    let first = test.submit("hello")
    let second = test.submit("thare")
    #expect(first)
    #expect(!second)
    #expect(test.currentWord == "world")
    // "hello" plus its space is six characters: 1.2 words in half a minute.
    #expect(test.wordsPerMinute(after: .seconds(30)) == 2.4)
    #expect(test.accuracy == 0.5)
    #expect(test.wordsPerMinute(after: .zero) == 0)
    #expect(TypingTest(words: []).currentWord == "blurt")
  }

  @Test("the ranks climb with speed")
  func ranks() {
    #expect(TypingTest.rank(for: 10).title == "Thumb wrestler")
    #expect(TypingTest.rank(for: 36).title == "Steady thumbs")
    #expect(TypingTest.rank(for: 200).title == "Are you even human?")
    #expect(TypingTest.randomWords(count: 7).count == 7)
  }

  @Test("a result sets time saved's speed and the best; too few words changes nothing; reset goes back to average")
  func speed() throws {
    let defaults = try scratchDefaults()
    #expect(TypingSpeed.current(in: defaults) == DictationStats.averageTypingWordsPerMinute)
    #expect(TypingSpeed.record(52.4, in: defaults) == .init(isBest: true, setsSpeed: true))
    #expect(TypingSpeed.current(in: defaults) == 52)
    #expect(TypingSpeed.record(40, in: defaults) == .init(isBest: false, setsSpeed: true))
    #expect(TypingSpeed.current(in: defaults) == 40)
    #expect(TypingSpeed.best(in: defaults) == 52.4)
    #expect(TypingSpeed.record(2, in: defaults) == .init(isBest: false, setsSpeed: false))
    #expect(TypingSpeed.current(in: defaults) == 40)
    TypingSpeed.resetToAverage(in: defaults)
    #expect(TypingSpeed.current(in: defaults) == DictationStats.averageTypingWordsPerMinute)
  }
}

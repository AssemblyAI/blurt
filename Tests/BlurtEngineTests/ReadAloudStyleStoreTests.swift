import Foundation
import Testing

@testable import BlurtAssemblyAI
@testable import BlurtEngine

@Suite("ReadAloudStyleStore")
struct ReadAloudStyleStoreTests {
  @Test("untouched: the default voice at natural pace, skipping jargon")
  func defaults() {
    #expect(ReadAloudStyleStore(defaults: freshDefaults()).style == ReadAloudStyle(rate: 1, skipsJargon: true))
    #expect(ReadAloudStyleStore.defaultSpeed == 1)
    #expect(ReadAloudStyleStore.defaultSkipsJargon)
  }

  @Test("speed and skipping are independent settings")
  func independent() {
    let defaults = freshDefaults()
    let store = ReadAloudStyleStore(defaults: defaults)
    defaults.set(1.5, forKey: ReadAloudStyleStore.speedDefaultsKey)
    #expect(store.style == ReadAloudStyle(rate: 1.5, skipsJargon: true))
    defaults.removeObject(forKey: ReadAloudStyleStore.speedDefaultsKey)
    defaults.set(false, forKey: ReadAloudStyleStore.skipsJargonDefaultsKey)
    #expect(store.style == ReadAloudStyle(rate: 1, skipsJargon: false))
  }

  @Test("a speed off the picker's list snaps to the nearest choice, and a non-number reads as the default")
  func snapsSpeed() {
    let defaults = freshDefaults()
    let store = ReadAloudStyleStore(defaults: defaults)
    defaults.set(9.0, forKey: ReadAloudStyleStore.speedDefaultsKey)
    #expect(store.style.rate == 3)
    defaults.set(0.1, forKey: ReadAloudStyleStore.speedDefaultsKey)
    #expect(store.style.rate == 1)
    defaults.set(1.6, forKey: ReadAloudStyleStore.speedDefaultsKey)
    #expect(store.style.rate == 1.5)
    defaults.set(1.65, forKey: ReadAloudStyleStore.speedDefaultsKey)
    #expect(store.style.rate == 1.75)
    defaults.set(Double.nan, forKey: ReadAloudStyleStore.speedDefaultsKey)
    #expect(store.style.rate == ReadAloudStyleStore.defaultSpeed)
    defaults.set("fast", forKey: ReadAloudStyleStore.speedDefaultsKey)
    #expect(store.style.rate == ReadAloudStyleStore.defaultSpeed)
  }

  @Test("untouched, no voice is named, so the provider speaks its default, aai-jane")
  func defaultVoice() {
    #expect(ReadAloudStyleStore(defaults: freshDefaults()).style.voiceID == nil)
    #expect(ReadAloudVoice.assemblyAIVoice(id: nil).id == "aai-jane")
    #expect(ReadAloudVoice.assemblyAIVoice(id: nil).group == .builtIn)
  }

  @Test("a chosen voice reads back")
  func voice() {
    let defaults = freshDefaults()
    let store = ReadAloudStyleStore(defaults: defaults)
    defaults.set("aai-yasmin", forKey: ReadAloudStyleStore.voiceDefaultsKey)
    #expect(store.style.voiceID == "aai-yasmin")
  }

  @Test("a blank voice slot names no voice")
  func blankVoice() {
    let defaults = freshDefaults()
    let store = ReadAloudStyleStore(defaults: defaults)
    defaults.set("  ", forKey: ReadAloudStyleStore.voiceDefaultsKey)
    #expect(store.style.voiceID == nil)
  }

  /// The retired bare name, a voice the service would refuse with 3012, and blank.
  @Test("a voice the catalog doesn't list resolves to the default", arguments: ["jane", "aai-nonexistent", ""])
  func staleVoice(stale: String) {
    #expect(ReadAloudVoice.assemblyAIVoice(id: stale).id == ReadAloudVoice.assemblyAIDefaultID)
  }

  @Test("the catalog: unique aai- slugs, built-ins first, the default leading, every voice labelled")
  func catalog() {
    let ids = ReadAloudVoice.assemblyAI.map(\.id)
    #expect(Set(ids).count == ids.count)
    #expect(ids.allSatisfy { $0.hasPrefix("aai-") && $0 == $0.lowercased() })
    #expect(ReadAloudVoice.assemblyAI.filter { $0.group == .builtIn }.count == 11)
    #expect(ReadAloudVoice.assemblyAI.first?.id == ReadAloudVoice.assemblyAIDefaultID)
    #expect(ReadAloudVoice.assemblyAIVoice(id: "aai-steven").label == "Steven (Australian)")
    #expect(ReadAloudVoice.assemblyAIVoice(id: "aai-gunnar").label == "Gunnar")
  }

  @Test("the default speed is one the picker offers")
  func defaultIsAChoice() {
    #expect(ReadAloudStyleStore.speedChoices.contains(ReadAloudStyleStore.defaultSpeed))
    #expect(ReadAloudStyleStore.speedChoices == ReadAloudStyleStore.speedChoices.sorted())
  }

  @Test("speed labels drop trailing zeros and follow the locale's decimal mark")
  func labels() {
    let english = Locale(identifier: "en_US")
    #expect(ReadAloudStyleStore.speedLabel(2, locale: english) == "2×")
    #expect(ReadAloudStyleStore.speedLabel(1.5, locale: english) == "1.5×")
    #expect(ReadAloudStyleStore.speedLabel(1.25, locale: english) == "1.25×")
    #expect(ReadAloudStyleStore.speedLabel(1.5, locale: Locale(identifier: "de_DE")) == "1,5×")
  }
}

import Foundation
import Testing

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

  @Test("untouched, the voice is the service's own default, aai-jane")
  func defaultVoice() {
    #expect(ReadAloudStyleStore(defaults: freshDefaults()).style.voiceID == "aai-jane")
    #expect(ReadAloudVoice.voice(id: ReadAloudStyleStore.defaultVoiceID)?.group == .builtIn)
  }

  @Test("a chosen voice reads back; one the catalog doesn't list reads as the default")
  func voice() {
    let defaults = freshDefaults()
    let store = ReadAloudStyleStore(defaults: defaults)
    defaults.set("aai-yasmin", forKey: ReadAloudStyleStore.voiceDefaultsKey)
    #expect(store.style.voiceID == "aai-yasmin")
    // The retired bare name, and a voice the service would refuse with 3012.
    for stale in ["jane", "aai-nonexistent", ""] {
      defaults.set(stale, forKey: ReadAloudStyleStore.voiceDefaultsKey)
      #expect(store.style.voiceID == ReadAloudStyleStore.defaultVoiceID)
    }
  }

  @Test("the catalog: unique aai- slugs, built-ins first, every voice labelled")
  func catalog() {
    let ids = ReadAloudVoice.catalog.map(\.id)
    #expect(Set(ids).count == ids.count)
    #expect(ids.allSatisfy { $0.hasPrefix("aai-") && $0 == $0.lowercased() })
    #expect(ReadAloudVoice.catalog.filter { $0.group == .builtIn }.count == 11)
    #expect(ReadAloudVoice.catalog.first?.id == ReadAloudVoice.defaultID)
    #expect(ReadAloudVoice.voice(id: "aai-steven")?.label == "Steven (Australian)")
    #expect(ReadAloudVoice.voice(id: "aai-gunnar")?.label == "Gunnar")
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

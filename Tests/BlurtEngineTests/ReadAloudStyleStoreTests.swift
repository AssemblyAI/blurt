import Foundation
import Testing

@testable import BlurtEngine

@Suite("ReadAloudStyleStore")
struct ReadAloudStyleStoreTests {
  @Test("untouched: natural pace, the selection verbatim")
  func defaultsToStandard() {
    #expect(ReadAloudStyleStore(defaults: freshDefaults()).style == .standard)
    #expect(ReadAloudStyleStore.defaultSpeed == 1)
    #expect(!ReadAloudStyleStore.defaultSkipsJargon)
  }

  @Test("speed and skipping are independent settings")
  func independent() {
    let defaults = freshDefaults()
    let store = ReadAloudStyleStore(defaults: defaults)
    defaults.set(1.5, forKey: ReadAloudStyleStore.speedDefaultsKey)
    #expect(store.style == ReadAloudStyle(rate: 1.5, skipsJargon: false))
    defaults.removeObject(forKey: ReadAloudStyleStore.speedDefaultsKey)
    defaults.set(true, forKey: ReadAloudStyleStore.skipsJargonDefaultsKey)
    #expect(store.style == ReadAloudStyle(rate: 1, skipsJargon: true))
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

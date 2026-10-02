import Foundation
import Testing

@testable import BlurtEngine

@Suite("ReadAloudWorkModeStore")
struct ReadAloudWorkModeStoreTests {
  @Test("off by default: natural pace, the selection verbatim")
  func defaultsToOff() {
    #expect(ReadAloudWorkModeStore(defaults: freshDefaults()).style == .standard)
  }

  @Test("switched on with nothing else touched: double speed, skipping jargon")
  func onWithDefaults() {
    let defaults = freshDefaults()
    defaults.set(true, forKey: ReadAloudWorkModeStore.defaultsKey)
    #expect(ReadAloudWorkModeStore(defaults: defaults).style == ReadAloudStyle(rate: 2, skipsJargon: true))
  }

  @Test("reads back the speed and jargon slots the Settings controls write")
  func readsCustomized() {
    let defaults = freshDefaults()
    defaults.set(true, forKey: ReadAloudWorkModeStore.defaultsKey)
    defaults.set(1.5, forKey: ReadAloudWorkModeStore.speedDefaultsKey)
    defaults.set(false, forKey: ReadAloudWorkModeStore.skipsJargonDefaultsKey)
    #expect(ReadAloudWorkModeStore(defaults: defaults).style == ReadAloudStyle(rate: 1.5, skipsJargon: false))
  }

  @Test("switching work mode off ignores a customized speed and jargon setting")
  func offIgnoresTheRest() {
    let defaults = freshDefaults()
    defaults.set(3.0, forKey: ReadAloudWorkModeStore.speedDefaultsKey)
    defaults.set(true, forKey: ReadAloudWorkModeStore.skipsJargonDefaultsKey)
    #expect(ReadAloudWorkModeStore(defaults: defaults).style == .standard)
  }

  @Test("a speed off the picker's list snaps to the nearest choice, and a non-number reads as the default")
  func snapsSpeed() {
    let defaults = freshDefaults()
    defaults.set(true, forKey: ReadAloudWorkModeStore.defaultsKey)
    let store = ReadAloudWorkModeStore(defaults: defaults)
    defaults.set(9.0, forKey: ReadAloudWorkModeStore.speedDefaultsKey)
    #expect(store.style.rate == 3)
    defaults.set(0.1, forKey: ReadAloudWorkModeStore.speedDefaultsKey)
    #expect(store.style.rate == 1)
    defaults.set(1.6, forKey: ReadAloudWorkModeStore.speedDefaultsKey)
    #expect(store.style.rate == 1.5)
    defaults.set(1.65, forKey: ReadAloudWorkModeStore.speedDefaultsKey)
    #expect(store.style.rate == 1.75)
    defaults.set(Double.nan, forKey: ReadAloudWorkModeStore.speedDefaultsKey)
    #expect(store.style.rate == ReadAloudWorkModeStore.defaultSpeed)
    defaults.set("fast", forKey: ReadAloudWorkModeStore.speedDefaultsKey)
    #expect(store.style.rate == ReadAloudWorkModeStore.defaultSpeed)
  }

  @Test("the default speed is one the picker offers")
  func defaultIsAChoice() {
    #expect(ReadAloudWorkModeStore.speedChoices.contains(ReadAloudWorkModeStore.defaultSpeed))
    #expect(ReadAloudWorkModeStore.speedChoices == ReadAloudWorkModeStore.speedChoices.sorted())
  }

  @Test("speed labels drop trailing zeros and follow the locale's decimal mark")
  func labels() {
    let english = Locale(identifier: "en_US")
    #expect(ReadAloudWorkModeStore.speedLabel(2, locale: english) == "2×")
    #expect(ReadAloudWorkModeStore.speedLabel(1.5, locale: english) == "1.5×")
    #expect(ReadAloudWorkModeStore.speedLabel(1.25, locale: english) == "1.25×")
    #expect(ReadAloudWorkModeStore.speedLabel(1.5, locale: Locale(identifier: "de_DE")) == "1,5×")
  }
}

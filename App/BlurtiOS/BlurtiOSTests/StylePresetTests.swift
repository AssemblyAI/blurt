import BlurtEngine
import Testing

@testable import BlurtiOSCore

@Suite("Style presets")
struct StylePresetTests {
  @Test("the phone allows 100 styles, and the three presets fit the store's caps")
  func fitTheCaps() {
    // The test host is the app, which configures the phone's limit at launch.
    #expect(StyleProfileStore.limit == 100)
    #expect(StylePreset.allCases.map(\.name) == ["Professional", "Casual", "Ultracasual"])
    for preset in StylePreset.allCases {
      #expect(preset.name.count <= StyleProfileStore.nameLimit)
      #expect(preset.instructions.utf8.count <= StyleProfileStore.characterLimit)
    }
  }

  @Test("adding a preset appends it once; an added one is found by name, whatever its text became")
  func adding() throws {
    let added = try #require(StylePreset.casual.adding(to: []))
    #expect(added.profiles.map(\.name) == ["Casual"])
    #expect(added.style.instructions == StylePreset.casual.instructions)
    var edited = added.style
    edited.instructions = "my own words"
    let again = try #require(StylePreset.casual.adding(to: [edited]))
    #expect(again.profiles == [edited])
    #expect(again.style == edited)
    #expect(StylePreset.casual.added(in: [StyleProfile(name: "casual", instructions: "x")]) != nil)
  }

  @Test("a full list takes no new preset, but still finds one already added")
  func full() {
    let full = (0..<StyleProfileStore.limit).map { StyleProfile(name: "Style \($0)", instructions: "x") }
    #expect(StylePreset.professional.adding(to: full) == nil)
    let withPreset = Array(full.dropLast()) + [StyleProfile(name: "Professional", instructions: "x")]
    #expect(StylePreset.professional.adding(to: withPreset)?.profiles == withPreset)
  }
}

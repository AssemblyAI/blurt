import Testing

@testable import BlurtEngine

@Suite("SoundPack")
struct SoundPackTests {
  @Test("none plays nothing and is labelled None")
  func none() {
    #expect(SoundPack.silent.label == "None")
    #expect(SoundPack.silent.group == nil)
    #expect(SoundPack.silent.startFileName == nil)
    #expect(SoundPack.silent.stopFileName == nil)
  }

  @Test("a voice exposes its name and cue stems")
  func voice() {
    let harp = SoundPack(id: "rom1b-28", label: "Harp 1", group: "Yamaha DX7 · ROM1B")
    #expect(harp.label == "Harp 1")
    #expect(harp.startFileName == "rom1b-28-start")
    #expect(harp.stopFileName == "rom1b-28-stop")
    // A group is what marks a real voice; only `.silent` is silent.
    #expect(!harp.isSilent)
  }
}

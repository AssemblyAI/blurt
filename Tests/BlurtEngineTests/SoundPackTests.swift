import Testing

@testable import BlurtEngine

@Suite("SoundPack")
struct SoundPackTests {
  @Test("none plays nothing and is labelled None")
  func none() {
    #expect(SoundPack.none.label == "None")
    #expect(SoundPack.none.group == nil)
    #expect(SoundPack.none.startFileName == nil)
    #expect(SoundPack.none.stopFileName == nil)
  }

  @Test("catalog covers DX7 (64) + Juno-106 (128), grouped by synth")
  func catalog() {
    #expect(SoundPack.catalog.count == 192)
    #expect(SoundPack.groups.first == "Yamaha DX7 · ROM1A")
    #expect(SoundPack.voices(in: "Yamaha DX7 · ROM1A").count == 32)
    #expect(SoundPack.voices(in: "Yamaha DX7 · ROM1B").count == 32)
    #expect(SoundPack.voices(in: "Roland Juno-106 · A").count == 64)
    #expect(SoundPack.voices(in: "Roland Juno-106 · B").count == 64)
  }

  @Test("a voice exposes its name and file stems")
  func voice() {
    let harp = SoundPack.find(id: "rom1b-28")
    #expect(harp?.label == "Harp 1")
    #expect(harp?.startFileName == "rom1b-28-start")
    #expect(harp?.stopFileName == "rom1b-28-stop")
    #expect(SoundPack.find(id: "rom1a-10")?.label == "E.Piano 1")
    #expect(SoundPack.find(id: "juno-0")?.label == "Brass")
  }

  @Test("synth credit names the source synth; nil for none")
  func synth() {
    #expect(SoundPack.none.synth == nil)
    #expect(SoundPack.find(id: "rom1a-6")?.synth == "Yamaha DX-7")
    #expect(SoundPack.find(id: "juno-13")?.synth == "Roland Juno-106")
  }

  @Test("default pack is Orchestra; lookups round-trip and reject unknowns")
  func lookup() {
    #expect(SoundPack.defaultPack.id == "rom1a-6")
    #expect(SoundPack.defaultPack.label == "Orchestra")
    #expect(SoundPack.find(id: "none") == SoundPack.none)
    #expect(SoundPack.find(id: "rom1a-0")?.label == "Brass 1")
    #expect(SoundPack.find(id: "trombone") == nil)
  }
}

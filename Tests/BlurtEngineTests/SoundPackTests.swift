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

  @Test("a voice exposes its name and cue stems")
  func voice() {
    let harp = SoundPack(id: "rom1b-28", label: "Harp 1", group: "Yamaha DX7 · ROM1B")
    #expect(harp.label == "Harp 1")
    #expect(harp.startFileName == "rom1b-28-start")
    #expect(harp.stopFileName == "rom1b-28-stop")
    // A group is what marks a real voice; only `.none` is silent.
    #expect(!harp.isSilent)
  }
}

/// The catalog is host-supplied now — the engine ships no voices, because the
/// `.m4a` files their stems name ship with whoever ships the bundle. So these
/// exercise the machinery against small fixtures rather than pinning Blurt's 192
/// generated entries; that the generated list and the audio agree is
/// `check.sh`'s catalog check, which is the only place the two halves meet.
@Suite("SoundPackCatalog")
struct SoundPackCatalogTests {
  private static let brass = SoundPack(id: "rom1a-0", label: "Brass 1", group: "DX7")
  private static let strings = SoundPack(id: "rom1a-3", label: "Strings 1", group: "DX7")
  private static let juno = SoundPack(id: "juno-0", label: "Brass", group: "Juno")

  private static let catalog = SoundPackCatalog(
    voices: [brass, strings, juno], defaultVoiceID: "rom1a-3")

  @Test("groups are the sections in catalog order, deduped")
  func groups() {
    #expect(Self.catalog.groups == ["DX7", "Juno"])
    #expect(Self.catalog.voices(in: "DX7") == [Self.brass, Self.strings])
    #expect(Self.catalog.voices(in: "Juno") == [Self.juno])
    // A section nobody declared is empty rather than a crash — the picker asks
    // only for names it got from `groups`, but a stale binding shouldn't trap.
    #expect(Self.catalog.voices(in: "Moog").isEmpty)
  }

  @Test("lookups round-trip and reject unknowns")
  func lookup() {
    #expect(Self.catalog.find(id: "rom1a-0") == Self.brass)
    #expect(Self.catalog.find(id: "trombone") == nil)
    // `.none` belongs to no catalog and is reachable from every one of them.
    #expect(Self.catalog.find(id: "none") == SoundPack.none)
  }

  @Test("an unset or unknown persisted id falls back to the default voice")
  func fromPersisted() {
    #expect(Self.catalog.defaultPack == Self.strings)
    #expect(Self.catalog.fromPersisted(nil) == Self.strings)
    #expect(Self.catalog.fromPersisted("") == Self.strings)
    #expect(Self.catalog.fromPersisted("trombone") == Self.strings)
    #expect(Self.catalog.fromPersisted("juno-0") == Self.juno)
    #expect(Self.catalog.fromPersisted("none") == SoundPack.none)
  }

  @Test("a default id naming no voice silences the cues instead of trapping")
  func unknownDefaultVoiceID() {
    // A host's catalog is data the engine can't validate at compile time. Falling
    // back to `.none` means a typo (or an empty catalog) costs the chimes, not the
    // launch.
    let broken = SoundPackCatalog(voices: [Self.brass], defaultVoiceID: "rom1a-6")
    #expect(broken.defaultPack == SoundPack.none)
    #expect(SoundPackCatalog(voices: [], defaultVoiceID: "rom1a-6").groups.isEmpty)
  }

  @Test("a voice claiming the reserved none id can't take away silence")
  func reservedNoneID() {
    // check.sh flags this collision in *this* repo; a host has no such gate, so
    // the resolution order is what guarantees "no sound" stays selectable. The
    // impostor loses its own slot, which is the harmless half of the trade.
    let impostor = SoundPack(id: "none", label: "Impostor", group: "DX7")
    let catalog = SoundPackCatalog(voices: [impostor], defaultVoiceID: "none")
    #expect(catalog.find(id: "none") == SoundPack.none)
    #expect(catalog.fromPersisted("none") == SoundPack.none)
  }
}

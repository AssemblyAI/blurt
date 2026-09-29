import Foundation
import Testing

@testable import BlurtiOS

@Suite("Key term list")
struct KeyTermListTests {
  @Test("parse trims, drops blanks, and deduplicates case-insensitively in first-seen order")
  func parse() {
    #expect(KeyTermList.parse(" Rizz , skibidi,,RIZZ, Blurt ,") == ["Rizz", "skibidi", "Blurt"])
  }

  @Test("join is what parse reads back")
  func roundTrip() {
    let terms = ["Neil Bisht", "AssemblyAI", "rizz"]
    #expect(KeyTermList.parse(KeyTermList.join(terms)) == terms)
  }

  @Test("an empty or all-blank list is empty")
  func empty() {
    #expect(KeyTermList.parse("").isEmpty)
    #expect(KeyTermList.parse(" , ,").isEmpty)
  }
}

@Suite("Phase snapshot staleness")
struct PhaseSnapshotTests {
  private func snapshot(_ state: PhaseSnapshot.State, ageSeconds: TimeInterval) -> PhaseSnapshot {
    PhaseSnapshot(state: state, message: nil, level: 0, at: Date().addingTimeInterval(-ageSeconds))
  }

  @Test("idle is never stale")
  func idle() {
    #expect(!snapshot(.idle, ageSeconds: 100_000).isStale)
  }

  @Test("a notice is over after three seconds")
  func notices() {
    for state in [PhaseSnapshot.State.pasted, .copied, .error] {
      #expect(!snapshot(state, ageSeconds: 2).isStale)
      #expect(snapshot(state, ageSeconds: 4).isStale)
    }
  }

  @Test("an in-flight state outlives no dictation past 130 seconds")
  func inFlight() {
    for state in [PhaseSnapshot.State.connecting, .recording, .processing] {
      #expect(!snapshot(state, ageSeconds: 120).isStale)
      #expect(snapshot(state, ageSeconds: 131).isStale)
    }
  }

  @Test("the dwell matches the design: 1.2 s pasted, 2 s copied and error, none otherwise")
  func dwell() {
    #expect(snapshot(.pasted, ageSeconds: 0).noticeDwellSeconds == 1.2)
    #expect(snapshot(.copied, ageSeconds: 0).noticeDwellSeconds == 2)
    #expect(snapshot(.error, ageSeconds: 0).noticeDwellSeconds == 2)
    #expect(snapshot(.recording, ageSeconds: 0).noticeDwellSeconds == nil)
  }
}

@Suite("Voice element setting")
struct VoiceElementSettingTests {
  @Test("the mic concept round-trips through the App Group; unset or unknown is the shipped one")
  func roundTrip() {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    #expect(SharedStore.voiceElementKind == .shipped)
    SharedStore.voiceElementKind = .streak
    #expect(SharedStore.voiceElementKind == .streak)
    SharedStore.defaults.set("z", forKey: BlurtShared.Key.voiceElement)
    #expect(SharedStore.voiceElementKind == .shipped)
  }
}

@Suite("Layouts and palettes")
struct LayoutTests {
  @Test("heights are the rows at the iPhone keyboard's spacing (DESIGN.md)")
  func heights() {
    #expect(KeyboardLayout.slimBar.height == 60)
    #expect(KeyboardLayout.panel.height == 216)
    #expect(KeyboardLayout.full.height == 270)
  }

  @Test("letter rows follow the phone's first language")
  func letterRows() {
    #expect(LetterLayout.forPreferredLanguages(["en-US", "fr-FR"]) == LetterLayout.qwerty)
    #expect(LetterLayout.forPreferredLanguages(["fr-CA"]) == LetterLayout.azerty)
    #expect(LetterLayout.forPreferredLanguages(["de-DE"]) == LetterLayout.qwertz)
    #expect(LetterLayout.forPreferredLanguages(["cs"]) == LetterLayout.qwertz)
    #expect(LetterLayout.forPreferredLanguages([]) == LetterLayout.qwerty)
  }

  @Test("every theme has a distinct id; the brand has two faces; an unknown or retired id is the brand's")
  func palettes() {
    let ids = KeyboardPalette.all.map(\.id)
    #expect(Set(ids).count == ids.count)
    #expect(KeyboardPalette.resolve("blurt", dark: true).face == .dark)
    #expect(KeyboardPalette.resolve("blurt", dark: false).keyText == DesignTokens.Themes.lightLegend)
    #expect(KeyboardPalette.resolve("blurt", dark: true).keyText == DesignTokens.Themes.darkLegend)
    #expect(KeyboardPalette.resolve("nope", dark: false).id == "blurt")
    #expect(KeyboardPalette.resolve("system", dark: true) == .brandDark)
    #expect(KeyboardPalette.brandLight != KeyboardPalette.brandDark)
  }
}

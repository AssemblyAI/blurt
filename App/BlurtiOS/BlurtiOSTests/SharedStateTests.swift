import BlurtDesign
import Foundation
import SwiftUI
import Testing

@testable import BlurtiOS
@testable import BlurtiOSCore

@Suite("Mic alignment setting")
struct MicAlignmentSettingTests {
  @Test("the mic's side round-trips through the App Group; unset or unknown is the middle")
  func roundTrip() {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    #expect(SharedStore.micAlignment == .center)
    SharedStore.micAlignment = .right
    #expect(SharedStore.micAlignment == .right)
    SharedStore.defaults.set("sideways", forKey: BlurtShared.Key.micAlignment)
    #expect(SharedStore.micAlignment == .center)
  }

  @Test("left and right are the phone's sides whatever the language reads in; the + leads only at the trailing edge")
  func sides() {
    #expect(MicAlignment.left.alignment(in: .leftToRight) == .leading)
    #expect(MicAlignment.left.alignment(in: .rightToLeft) == .trailing)
    #expect(MicAlignment.right.alignment(in: .leftToRight) == .trailing)
    #expect(MicAlignment.right.alignment(in: .rightToLeft) == .leading)
    #expect(MicAlignment.center.alignment(in: .rightToLeft) == .center)
    #expect(MicAlignment.right.plusLeads(in: .leftToRight))
    #expect(MicAlignment.left.plusLeads(in: .rightToLeft))
    #expect(!MicAlignment.left.plusLeads(in: .leftToRight))
    #expect(!MicAlignment.center.plusLeads(in: .leftToRight))
  }

  @Test("the gallery and probe words name a side")
  func parse() {
    #expect(MicAlignment.parse(["-BlurtGallery", "panel", "idle", "-BlurtGalleryAlign", "right"]) == .right)
    #expect(MicAlignment.parse(["-BlurtGallery", "panel", "idle"]) == nil)
    #expect(MicAlignment(rawValue: "left") == .left)
  }
}

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

@Suite("Shared defaults")
@MainActor
struct SharedDefaultsTests {
  @Test("a payload round-trips through the App Group; unreadable or removed is nothing")
  func payloads() {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let result = DictationResult(id: UUID(), text: "hi", deliveredAt: Date(), recipient: "kb")
    SharedStore.write(result, forKey: BlurtShared.Key.result)
    #expect(SharedStore.read(DictationResult.self, forKey: BlurtShared.Key.result)?.id == result.id)
    SharedStore.defaults.set(Data("not json".utf8), forKey: BlurtShared.Key.result)
    #expect(SharedStore.read(DictationResult.self, forKey: BlurtShared.Key.result) == nil)
    SharedStore.write(result, forKey: BlurtShared.Key.result)
    SharedStore.remove(forKey: BlurtShared.Key.result)
    #expect(SharedStore.read(DictationResult.self, forKey: BlurtShared.Key.result) == nil)
  }

  @Test("each setting has its default until chosen, and keeps what was chosen")
  func settings() {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    #expect(SharedStore.layout == .panel)
    SharedStore.layout = .full
    #expect(SharedStore.layout == .full)
    #expect(SharedStore.themeID == "system")
    SharedStore.themeID = "blurt"
    #expect(SharedStore.themeID == "blurt")
    #expect(SharedStore.autoDictate)
    SharedStore.autoDictate = false
    #expect(!SharedStore.autoDictate)
    #expect(SharedStore.windowMinutes == 15)
    // 0 is a real choice (until closed), not the unset default.
    SharedStore.windowMinutes = 0
    #expect(SharedStore.windowMinutes == 0)
    #expect(SharedStore.lexiconRefreshedAt == nil)
  }

  @Test("a contact name has both sides equal; a text replacement does not")
  func lexiconEntries() {
    #expect(LexiconEntry(userInput: "Neil Bisht", documentText: "Neil Bisht").isName)
    #expect(!LexiconEntry(userInput: "omw", documentText: "On my way!").isName)
  }
}

@Suite("Layouts and palettes")
struct LayoutTests {
  @Test("every layout and mic side has its own name and description for Settings")
  func settingsCopy() {
    for cases in [
      KeyboardLayout.allCases.map { ($0.id, $0.title, $0.summary) },
      MicAlignment.allCases.map { ($0.id, $0.title, $0.summary) },
    ] {
      #expect(Set(cases.map(\.0)).count == cases.count)
      #expect(Set(cases.map(\.1)).count == cases.count)
      #expect(Set(cases.map(\.2)).count == cases.count)
      #expect(cases.allSatisfy { !$0.1.isEmpty && !$0.2.isEmpty })
    }
    #expect(KeyboardLayout.full.id == "full")
    #expect(MicAlignment.left.id == "left")
  }

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

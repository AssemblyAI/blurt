import BlurtDesign
import Foundation
import Testing

@testable import BlurtiOS
@testable import BlurtiOSCore

@Suite("Voice element")
struct VoiceElementTests {
  @Test("the kind is read from -BlurtGalleryVoice, and only a, b or c")
  func kind() {
    #expect(VoiceElementKind.parse(["app"]) == nil)
    #expect(VoiceElementKind.parse(["app", "-BlurtGalleryVoice"]) == nil)
    #expect(VoiceElementKind.parse(["app", "-BlurtGalleryVoice", "a"]) == .grille)
    #expect(VoiceElementKind.parse(["app", "-BlurtGalleryVoice", "b"]) == .ribs)
    #expect(VoiceElementKind.parse(["app", "-BlurtGalleryVoice", "c"]) == .streak)
    #expect(VoiceElementKind.parse(["app", "-BlurtGalleryVoice", "d"]) == nil)
  }

  @Test("the landing glint runs 0 → 1 over motion.landing and is gone after")
  func landing() {
    let landedAt = Date()
    #expect(VoiceClock.landing(landedAt: nil, now: landedAt) == nil)
    #expect(VoiceClock.landing(landedAt: landedAt, now: landedAt.addingTimeInterval(-0.1)) == nil)
    #expect(VoiceClock.landing(landedAt: landedAt, now: landedAt) == 0)
    let half = VoiceClock.landing(landedAt: landedAt, now: landedAt.addingTimeInterval(DesignTokens.Motion.landing / 2))
    #expect(half != nil && abs((half ?? 0) - 0.5) < 0.001)
    #expect(
      VoiceClock.landing(landedAt: landedAt, now: landedAt.addingTimeInterval(DesignTokens.Motion.landing)) == nil)
  }

  @Test("the sheen runs on the rest period, faster while working, and the facet hash is stable")
  func clocks() {
    #expect(VoiceClock.sheen(time: 0, working: false) == 0)
    #expect(abs(VoiceClock.sheen(time: DesignTokens.Motion.sheen / 2, working: false) - 0.5) < 0.001)
    #expect(abs(VoiceClock.sheen(time: DesignTokens.Motion.sheenWorking / 4, working: true) - 0.25) < 0.001)
    #expect(VoiceClock.hash(3, 7) == VoiceClock.hash(3, 7))
    #expect(VoiceClock.hash(3, 7) != VoiceClock.hash(4, 7))
    #expect((0..<64).allSatisfy { (0...1).contains(VoiceClock.hash($0, 1)) })
  }

  @Test("the bar pairs the + with what shows: the grille's own width, the ribs asleep or awake, the streak's line")
  func visibleWidth() {
    let metrics = DesignTokens.Metrics.self
    #expect(VoiceElementKind.grille.visibleWidth(slot: .bar, recording: false) == metrics.grilleBarWidth)
    #expect(VoiceElementKind.grille.visibleWidth(slot: .bar, recording: true) == metrics.grilleBarWidth)
    #expect(VoiceElementKind.grille.visibleWidth(slot: .panel, recording: false) == metrics.grillePanelWidth)
    #expect(VoiceElementKind.ribs.visibleWidth(slot: .bar, recording: false) == metrics.ribsRestWidth)
    #expect(VoiceElementKind.ribs.visibleWidth(slot: .bar, recording: true) == metrics.voiceBarWidth)
    #expect(VoiceElementKind.streak.visibleWidth(slot: .bar, recording: false) == metrics.voiceBarWidth)
    // Every candidate fits its slot's box.
    for kind in VoiceElementKind.allCases {
      for slot in VoiceSlot.allCases {
        #expect(kind.visibleWidth(slot: slot, recording: false) <= slot.box.width)
        #expect(kind.visibleWidth(slot: slot, recording: true) <= slot.box.width)
      }
    }
  }

  @Test("every slot has a box, from the tokens")
  func slots() {
    #expect(VoiceSlot.bar.box.width == DesignTokens.Metrics.voiceBarWidth)
    #expect(VoiceSlot.panel.box.height == DesignTokens.Metrics.voicePanelHeight)
    #expect(
      VoiceSlot.home.box
        == CGSize(width: DesignTokens.Metrics.voiceHomeWidth, height: DesignTokens.Metrics.voiceHomeHeight))
  }
}

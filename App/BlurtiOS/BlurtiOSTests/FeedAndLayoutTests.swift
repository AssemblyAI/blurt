import BlurtDesign
import Foundation
import Testing

@testable import BlurtiOS
@testable import BlurtiOSCore

@Suite("Utterance feed")
struct UtteranceFeedTests {
  private func pcm(_ samples: [Int16]) -> Data {
    samples.withUnsafeBufferPointer { Data(buffer: $0) }
  }

  @Test("level: silence is 0, full scale is 1, room ambient under the floor is 0")
  func level() {
    #expect(UtteranceFeed.level(of: pcm([0, 0, 0, 0])) == 0)
    #expect(UtteranceFeed.level(of: pcm([Int16.max, Int16.max, -Int16.max, -Int16.max])) == 1)
    #expect(UtteranceFeed.level(of: pcm([3, -3, 2, -2])) == 0)
    #expect(UtteranceFeed.level(of: Data()) == 0)
    let mid = UtteranceFeed.level(of: pcm([8000, -8000, 8000, -8000]))
    #expect(mid > 0 && mid < 1)
  }

  @Test("digital silence is all zeros; a quiet room's noise floor is not")
  func digitalSilence() {
    #expect(UtteranceFeed.isDigitalSilence(pcm([0, 0, 0, 0])))
    #expect(!UtteranceFeed.isDigitalSilence(pcm([0, 1, 0, 0])))
    #expect(!UtteranceFeed.isDigitalSilence(pcm([3, -3, 2, -2])))
  }

  @Test("chunks reach the utterance between begin and end, the tally counts them, and nothing outside")
  func tally() async {
    let feed = UtteranceFeed()
    feed.deliver(pcm([1000, -1000]))
    #expect(!feed.isCapturing)
    let stream = feed.begin()
    #expect(feed.isCapturing)
    feed.deliver(pcm([1000, -1000]))
    feed.deliver(pcm([1000, -1000, 1000]))
    let bytes = feed.end()
    #expect(bytes == 10)
    #expect(!feed.isCapturing)
    var received = 0
    for await chunk in stream { received += chunk.count }
    #expect(received == 10)
    feed.deliver(pcm([1]))
    #expect(feed.end() == 0)
  }
}

@Suite("Layout arithmetic")
struct LayoutArithmeticTests {
  /// The gallery's stand-in profile: the brand's faces are the same on
  /// either generation, which is all these rows check.
  private static let profile = KeyboardProfile.standIn(width: 390)

  @Test("the full layout's height is its rows at the profile's spacing (DESIGN.md)")
  func fullHeight() {
    for generation in [KeyboardProfile.Generation.classic, .glass] {
      let profile = KeyboardProfile(generation: generation, width: 390, hasGlobe: false)
      let expected = profile.topBand + 4 * profile.keyHeight + 3 * profile.rowGap + profile.bottomInset
      #expect(KeyboardLayout.full.height(profile: profile) == expected, "\(generation)")
      #expect(profile.topBand == profile.marginTop + VoiceBar.height)
    }
  }

  @Test("the gallery reads a layout, states and an optional theme from the launch arguments")
  func galleryRows() {
    #expect(KeyboardGalleryView.rows(from: ["app"]).isEmpty)
    #expect(KeyboardGalleryView.rows(from: ["app", "-BlurtGallery", "panel"]).isEmpty)
    #expect(KeyboardGalleryView.rows(from: ["app", "-BlurtGallery", "nope", "idle"]).isEmpty)
    let rows = KeyboardGalleryView.rows(from: ["app", "-BlurtGallery", "panel", "idle,keys,term", "dark"])
    #expect(rows.count == 3)
    #expect(rows[1].model.effectiveLayout == .full)
    #expect(rows[2].model.termDraft == "Rizz")
    #expect(rows[0].model.palette(for: Self.profile).face == .dark)
    // The old theme words still land on a face, so a capture script never breaks.
    let dark = KeyboardGalleryView.rows(from: ["app", "-BlurtGallery", "full", "idle", "system-dark"])
    #expect(dark[0].model.palette(for: Self.profile).keyText == DesignTokens.Themes.darkLegend)
    let ink = KeyboardGalleryView.rows(from: ["app", "-BlurtGallery", "full", "idle", "ink"])
    #expect(ink[0].model.palette(for: Self.profile).face == .dark)
    #expect(
      KeyboardGalleryView.rows(from: ["app", "-BlurtGallery", "full", "idle", "paper"])[0]
        .model.palette(for: Self.profile).face == .light)
  }

  @Test("the capture switches ride along, and a switch where the theme would be is not a theme")
  func galleryOptions() {
    let args = ["app", "-BlurtGallery", "panel", "idle", "-BlurtGalleryStill", "-BlurtGalleryBare"]
    #expect(KeyboardGalleryView.rows(from: args)[0].model.palette(for: Self.profile).face == .light)
    #expect(KeyboardGalleryView.Options.parse(args) == .init(still: true, bare: true))
    #expect(KeyboardGalleryView.Options.parse(["app", "-BlurtGallery", "panel", "idle", "dark"]) == .init())
    #expect(KeyboardGalleryView.rows(from: args)[0].model.voiceKind == .shipped)
    #expect(KeyboardGalleryView.rows(from: args + ["-BlurtGalleryVoice", "b"])[0].model.voiceKind == .ribs)
    #expect(KeyboardGalleryView.rows(from: args + ["-BlurtGalleryVoice", "z"])[0].model.voiceKind == .shipped)
    #expect(KeyboardGalleryView.VoiceStillView.parse(args) == nil)
    let voice = KeyboardGalleryView.VoiceStillView.parse(["app", "-BlurtVoice", "a", "panel", "landed", "dark"])
    #expect(voice?.kind == .grille)
    #expect(voice?.slot == .panel)
    #expect(voice?.landedAt != nil)
    #expect(voice?.dark == true)
    #expect(
      KeyboardGalleryView.VoiceStillView.parse(["app", "-BlurtVoice", "c", "bar", "recording"])?.state.level == 0.62)
    #expect(KeyboardGalleryView.VoiceStillView.parse(["app", "-BlurtVoice", "a", "bar", "nope"]) == nil)
    #expect(KeyboardGalleryView.VoiceStillView.parse(["app", "-BlurtVoice", "d", "bar", "idle"]) == nil)
    #expect(KeyboardGalleryView.VoiceStillView.parse(["app", "-BlurtVoice", "a", "desk", "idle"]) == nil)
  }
}

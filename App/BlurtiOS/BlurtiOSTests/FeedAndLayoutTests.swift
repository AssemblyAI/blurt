import Foundation
import Testing

@testable import BlurtiOS

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

  @Test("chunks reach the utterance between begin and end, the tally counts them, and nothing outside")
  func tally() async {
    let feed = UtteranceFeed()
    feed.deliver(pcm([1000, -1000]))
    let stream = feed.begin()
    feed.deliver(pcm([1000, -1000]))
    feed.deliver(pcm([1000, -1000, 1000]))
    let bytes = feed.end()
    #expect(bytes == 10)
    var received = 0
    for await chunk in stream { received += chunk.count }
    #expect(received == 10)
    feed.deliver(pcm([1]))
    #expect(feed.end() == 0)
  }
}

@Suite("Layout arithmetic")
struct LayoutArithmeticTests {
  @Test("the full layout's height is its rows at the theme spacing (DESIGN.md)")
  func fullHeight() {
    let expected =
      2 * KeyboardRootView.verticalMargin + VoiceBar.height + 4 * KeyboardPalette.rowGap + 4 * KeyCap.height
    #expect(KeyboardLayout.full.height == expected)
  }

  @Test("the gallery reads a layout, states and an optional theme from the launch arguments")
  func galleryRows() {
    #expect(KeyboardGalleryView.rows(from: ["app"]).isEmpty)
    #expect(KeyboardGalleryView.rows(from: ["app", "-BlurtGallery", "panel"]).isEmpty)
    #expect(KeyboardGalleryView.rows(from: ["app", "-BlurtGallery", "nope", "idle"]).isEmpty)
    let rows = KeyboardGalleryView.rows(from: ["app", "-BlurtGallery", "panel", "idle,keys,term", "mint"])
    #expect(rows.count == 3)
    #expect(rows[1].model.effectiveLayout == .full)
    #expect(rows[2].model.termDraft == "Rizz")
    #expect(rows[0].model.palette.id == "mint")
    let dark = KeyboardGalleryView.rows(from: ["app", "-BlurtGallery", "full", "idle", "system-dark"])
    #expect(dark[0].model.palette.keyText == .white)
  }
}

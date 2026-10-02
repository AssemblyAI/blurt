import Testing

@testable import BlurtiOS

@Suite("Panel carousel")
struct PanelCarouselTests {
  @Test("a flip slides a page towards the finger, and settling puts the other page in the middle")
  func flipAndSettle() {
    var strip = PanelCarouselState(keysUp: false)
    let left = strip.flip(to: true, towardsLeading: true, animated: true)
    #expect(left == PanelCarouselState.Motion(slide: -1, generation: 1))
    #expect(strip.incomingEdge == .trailing)
    #expect(!strip.keysUp && strip.target && strip.inFlight)
    let settled = strip.settle(1)
    #expect(settled && strip.keysUp && !strip.inFlight)
    // From the keys, a swipe right brings the panel in from the leading side.
    let right = strip.flip(to: false, towardsLeading: false, animated: true)
    #expect(right == PanelCarouselState.Motion(slide: 1, generation: 2))
    #expect(strip.incomingEdge == .leading)
    let back = strip.settle(2)
    #expect(back && !strip.keysUp)
  }

  @Test("two swipes the same way wrap: the incoming page is set down on the same side each time")
  func wrap() {
    var strip = PanelCarouselState(keysUp: false)
    let first = strip.flip(to: true, towardsLeading: true, animated: true)
    #expect(first?.slide == -1)
    let firstSettled = strip.settle(1)
    #expect(firstSettled)
    let second = strip.flip(to: false, towardsLeading: true, animated: true)
    #expect(second?.slide == -1)
    #expect(strip.incomingEdge == .trailing)
    let secondSettled = strip.settle(2)
    #expect(secondSettled && !strip.keysUp)
  }

  @Test("a flip back mid-slide retreats, and the overtaken slide cannot settle the strip")
  func retreat() {
    var strip = PanelCarouselState(keysUp: false)
    let out = strip.flip(to: true, towardsLeading: true, animated: true)
    #expect(out?.generation == 1)
    let back = strip.flip(to: false, towardsLeading: false, animated: true)
    #expect(back == PanelCarouselState.Motion(slide: 0, generation: 2))
    #expect(strip.incomingEdge == .trailing, "the page on its way in retreats where it came from")
    let late = strip.settle(1)
    #expect(!late, "the first slide's ending is too late")
    #expect(strip.inFlight && !strip.keysUp)
    let settled = strip.settle(2)
    #expect(settled && !strip.keysUp && !strip.inFlight)
  }

  @Test("a retreat cut short by another flip keeps the incoming page's side")
  func retreatCutShort() {
    var strip = PanelCarouselState(keysUp: false)
    _ = strip.flip(to: true, towardsLeading: true, animated: true)
    _ = strip.flip(to: false, towardsLeading: false, animated: true)
    let again = strip.flip(to: true, towardsLeading: false, animated: true)
    #expect(again == PanelCarouselState.Motion(slide: -1, generation: 3))
    #expect(strip.incomingEdge == .trailing)
    let settled = strip.settle(3)
    #expect(settled && strip.keysUp)
  }

  @Test("without motion a flip settles at once, with nothing to animate")
  func still() {
    var strip = PanelCarouselState(keysUp: false)
    let still = strip.flip(to: true, towardsLeading: true, animated: false)
    #expect(still == nil && strip.keysUp && !strip.inFlight)
    let same = strip.flip(to: true, towardsLeading: true, animated: true)
    #expect(same == nil, "already there: nothing moves")
  }
}

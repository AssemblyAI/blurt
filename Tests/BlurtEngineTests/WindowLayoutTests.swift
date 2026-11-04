import CoreGraphics
import Testing

@testable import BlurtEngine

@Suite("WindowLayout")
struct WindowLayoutTests {
  /// A 1512×945 display with a 33-point menu bar and no Dock below it, in
  /// Accessibility's top-left coordinates.
  private let visible = CGRect(x: 0, y: 33, width: 1512, height: 912)
  private let window = CGRect(x: 200, y: 150, width: 800, height: 600)

  @Test("halves and maximize fill the display's usable area, under the menu bar")
  func halves() {
    #expect(WindowLayout.frame(for: .maximize, window: window, visible: visible) == visible)
    #expect(
      WindowLayout.frame(for: .leftHalf, window: window, visible: visible)
        == CGRect(x: 0, y: 33, width: 756, height: 912))
    #expect(
      WindowLayout.frame(for: .rightHalf, window: window, visible: visible)
        == CGRect(x: 756, y: 33, width: 756, height: 912))
    #expect(
      WindowLayout.frame(for: .topHalf, window: window, visible: visible)
        == CGRect(x: 0, y: 33, width: 1512, height: 456))
    #expect(
      WindowLayout.frame(for: .bottomHalf, window: window, visible: visible)
        == CGRect(x: 0, y: 489, width: 1512, height: 456))
  }

  @Test("center keeps the size, shrunk to fit, and minimize, full screen and next display aren't frames")
  func centerAndOthers() {
    #expect(
      WindowLayout.frame(for: .center, window: window, visible: visible)
        == CGRect(x: 356, y: 189, width: 800, height: 600))
    let huge = CGRect(x: 0, y: 0, width: 3000, height: 2000)
    #expect(WindowLayout.frame(for: .center, window: huge, visible: visible) == visible)
    for operation in [WindowOperation.minimize, .fullScreen, .nextDisplay] {
      #expect(WindowLayout.frame(for: operation, window: window, visible: visible) == nil)
    }
  }

  @Test("next display keeps the window's place relative to its display, and wraps round")
  func nextDisplay() {
    let left = CGRect(x: 0, y: 33, width: 1512, height: 912)
    let right = CGRect(x: 1512, y: 0, width: 1920, height: 1080)
    let moved = WindowLayout.onNextDisplay(CGRect(x: 0, y: 33, width: 800, height: 600), displays: [left, right])
    #expect(moved == CGRect(x: 1512, y: 0, width: 800, height: 600))
    let back = WindowLayout.onNextDisplay(CGRect(x: 2632, y: 480, width: 800, height: 600), displays: [left, right])
    #expect(back?.minX == 712)
    #expect(WindowLayout.onNextDisplay(window, displays: [left]) == nil)
  }

  @Test("an AppKit display frame flips to Accessibility's top-left coordinates")
  func flip() {
    let primaryHeight: CGFloat = 982
    #expect(
      WindowLayout.accessibilityFrame(CGRect(x: 0, y: 0, width: 1512, height: 949), primaryHeight: primaryHeight)
        == CGRect(x: 0, y: 33, width: 1512, height: 949))
  }

  @Test("each scroll direction has its page action and a wheel the right way round")
  func scrollDirections() {
    #expect(ScrollDirection.down.pageAction == "AXScrollDownByPage")
    #expect(ScrollDirection.down.wheelLines.vertical < 0)
    #expect(ScrollDirection.up.wheelLines.vertical > 0)
    #expect(ScrollDirection.right.wheelLines.horizontal < 0)
    // The ends go by the scroll bar: 0 at the top, 1 at the bottom, with no
    // page action, and a wheel far enough to reach them.
    #expect(ScrollDirection.top.pageAction == nil && ScrollDirection.bottom.pageAction == nil)
    #expect(ScrollDirection.top.scrollBarValue == 0 && ScrollDirection.bottom.scrollBarValue == 1)
    #expect(ScrollDirection.down.scrollBarValue == nil)
    #expect(
      ScrollDirection.bottom.wheelLines.vertical
        < ScrollDirection.down.wheelLines.vertical)
  }
}

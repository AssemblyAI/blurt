import CoreGraphics

/// Which way a `scroll` step goes: a page at a time, or all the way to the
/// top or the bottom.
public enum ScrollDirection: String, CaseIterable, Sendable {
  case up, down, left, right, top, bottom

  /// The Accessibility action that scrolls a scroll area a page this way;
  /// nil for the two ends, which are set on the scroll bar instead.
  var pageAction: String? {
    switch self {
    case .up: "AXScrollUpByPage"
    case .down: "AXScrollDownByPage"
    case .left: "AXScrollLeftByPage"
    case .right: "AXScrollRightByPage"
    case .top, .bottom: nil
    }
  }

  /// Where the vertical scroll bar's value (0 at the top, 1 at the bottom)
  /// goes for the two ends.
  var scrollBarValue: Double? {
    switch self {
    case .top: 0
    case .bottom: 1
    default: nil
    }
  }

  /// The scroll-wheel event for the fallback, in lines: (vertical,
  /// horizontal), positive up and left as `CGEvent` counts them — whatever
  /// the natural-scrolling setting, which a synthesized wheel doesn't go
  /// through (measured in Preview, 2026-11-04). An end is a wheel turned far
  /// enough to reach it.
  var wheelLines: (vertical: Int32, horizontal: Int32) {
    switch self {
    case .up: (10, 0)
    case .down: (-10, 0)
    case .left: (0, 10)
    case .right: (0, -10)
    case .top: (10_000, 0)
    case .bottom: (-10_000, 0)
    }
  }
}

/// What a `window` step does to the frontmost app's focused window.
public enum WindowOperation: String, CaseIterable, Sendable {
  case minimize
  case fullScreen = "full_screen"
  case maximize
  case center
  case leftHalf = "left_half"
  case rightHalf = "right_half"
  case topHalf = "top_half"
  case bottomHalf = "bottom_half"
  case nextDisplay = "next_display"
}

/// Where a `window` step puts a window, apart from the system so it's
/// tested. Every rectangle is in Accessibility's global coordinates — top-left
/// origin at the primary display's top-left, y growing down — the ones
/// `kAXPosition` takes. `visible` is a display's frame less the menu bar and
/// the Dock (`NSScreen.visibleFrame`, flipped by `accessibilityFrame`).
enum WindowLayout {
  /// The frame for `operation`, for a window now at `window` on the display
  /// whose usable area is `visible`. Nil for the operations that aren't a
  /// frame (minimize, full screen, next display).
  static func frame(for operation: WindowOperation, window: CGRect, visible: CGRect) -> CGRect? {
    switch operation {
    case .maximize: return visible
    case .center:
      let size = CGSize(width: min(window.width, visible.width), height: min(window.height, visible.height))
      return CGRect(
        x: visible.midX - size.width / 2, y: visible.midY - size.height / 2, width: size.width, height: size.height)
    case .leftHalf: return CGRect(x: visible.minX, y: visible.minY, width: visible.width / 2, height: visible.height)
    case .rightHalf:
      return CGRect(x: visible.midX, y: visible.minY, width: visible.width / 2, height: visible.height)
    case .topHalf: return CGRect(x: visible.minX, y: visible.minY, width: visible.width, height: visible.height / 2)
    case .bottomHalf:
      return CGRect(x: visible.minX, y: visible.midY, width: visible.width, height: visible.height / 2)
    case .minimize, .fullScreen, .nextDisplay: return nil
    }
  }

  /// The window moved to the next display along `displays` (each one's
  /// usable area, in order), keeping its place and size relative to the
  /// display it's leaving, shrunk to fit. Nil with one display.
  static func onNextDisplay(_ window: CGRect, displays: [CGRect]) -> CGRect? {
    guard displays.count > 1 else { return nil }
    let current = displays.firstIndex { $0.contains(CGPoint(x: window.midX, y: window.midY)) } ?? 0
    let from = displays[current]
    let to = displays[(current + 1) % displays.count]
    let size = CGSize(width: min(window.width, to.width), height: min(window.height, to.height))
    let relativeX = from.width > window.width ? (window.minX - from.minX) / (from.width - window.width) : 0
    let relativeY = from.height > window.height ? (window.minY - from.minY) / (from.height - window.height) : 0
    return CGRect(
      x: to.minX + max(0, min(1, relativeX)) * (to.width - size.width),
      y: to.minY + max(0, min(1, relativeY)) * (to.height - size.height), width: size.width, height: size.height)
  }

  /// A display's frame in Accessibility's coordinates, from AppKit's
  /// bottom-left ones: `primaryHeight` is the primary display's height,
  /// which both systems share as their origin's line.
  static func accessibilityFrame(_ appKit: CGRect, primaryHeight: CGFloat) -> CGRect {
    CGRect(x: appKit.minX, y: primaryHeight - appKit.maxY, width: appKit.width, height: appKit.height)
  }
}

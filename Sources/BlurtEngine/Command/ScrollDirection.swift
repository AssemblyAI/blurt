/// Which way a `scroll` step goes: a page at a time, or all the way to the
/// top or the bottom.
public enum ScrollDirection: String, CaseIterable, Sendable {
  case up, down, left, right, top, bottom

  /// The Accessibility action that scrolls a scroll area a page this way;
  /// nil for the two ends, which are set on the scroll bar instead.
  var pageAction: String? {
    switch self {
    case .up:
      "AXScrollUpByPage"

    case .down:
      "AXScrollDownByPage"

    case .left:
      "AXScrollLeftByPage"

    case .right:
      "AXScrollRightByPage"

    case .top, .bottom:
      nil
    }
  }

  /// Where the vertical scroll bar's value (0 at the top, 1 at the bottom)
  /// goes for the two ends.
  var scrollBarValue: Double? {
    switch self {
    case .top:
      0

    case .bottom:
      1

    default:
      nil
    }
  }

  /// The scroll-wheel event for the fallback, in lines: (vertical,
  /// horizontal), positive up and left as `CGEvent` counts them — whatever
  /// the natural-scrolling setting, which a synthesized wheel doesn't go
  /// through (measured in Preview, 2026-11-04). An end is a wheel turned far
  /// enough to reach it.
  var wheelLines: (vertical: Int32, horizontal: Int32) {
    switch self {
    case .up:
      (10, 0)

    case .down:
      (-10, 0)

    case .left:
      (0, 10)

    case .right:
      (0, -10)

    case .top:
      (10_000, 0)

    case .bottom:
      (-10_000, 0)
    }
  }
}

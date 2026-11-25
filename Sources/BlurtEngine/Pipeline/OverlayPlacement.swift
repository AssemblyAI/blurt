public import CoreGraphics

/// Where the overlay pill's panel goes on screen — pure geometry, owned in the
/// engine so the placement rules are unit-tested. The AppKit controller feeds
/// in the screen's visible frame and the persisted drag origin; only the
/// `NSScreen`/`NSPanel` plumbing stays in the shell.
public enum OverlayPlacement {
  /// Default clearance between the bottom of the *visible pill* and the bottom of
  /// the screen's visible frame.
  ///
  /// Measured to the pill, not the panel: the panel is deliberately larger so the
  /// drop shadow isn't clipped, so a caller placing the panel must back this off
  /// by that transparent inset. `panelOrigin(…shadowMargin:)` does that here,
  /// where it's unit-tested — when the arithmetic lived at the AppKit call site,
  /// changing the shadow margin silently moved the pill and no test noticed.
  public static let defaultBottomClearance: CGFloat = 80

  /// The panel size that holds a `pillSize` pill with `shadowMargin` of
  /// transparent room on all four sides, so the pill's drop shadow renders its
  /// full falloff instead of being clipped by the window's contentRect.
  ///
  /// Here rather than at the AppKit call site for the same reason
  /// `panelOrigin` backs the clearance off by the margin: the pill/panel
  /// relationship is one fact, and half of it living in the shell meant a change
  /// to the margin only got checked on one side. Same split as
  /// `RecentDictations.reservedHeight` — the shell owns the measurements, the
  /// engine owns the arithmetic over them.
  public static func panelSize(pillSize: CGSize, shadowMargin: CGFloat) -> CGSize {
    CGSize(
      width: pillSize.width + shadowMargin * 2,
      height: pillSize.height + shadowMargin * 2
    )
  }

  /// Resolves the *panel* origin from what the shell genuinely owns — the screen's
  /// visible frame, the persisted drag origin, and the panel's transparent shadow
  /// inset — keeping the clearance policy and the pill/panel conversion in here.
  public static func panelOrigin(
    panelSize: CGSize,
    visibleFrame: CGRect,
    customOrigin: CGPoint?,
    shadowMargin: CGFloat
  ) -> CGPoint {
    origin(
      panelSize: panelSize,
      visibleFrame: visibleFrame,
      customOrigin: customOrigin,
      bottomOffset: defaultBottomClearance - shadowMargin
    )
  }

  /// The visible frame to place the panel in: that of the connected screen a
  /// dragged `customOrigin` puts most of the panel on, else `fallback` (the
  /// shell's `NSScreen.main`). With no dragged origin the pill follows the
  /// active screen, so that is `fallback` too.
  ///
  /// The clamp in `origin` is for an origin left on a monitor since unplugged.
  /// Given only the active screen, it also caught a pill dragged onto a second
  /// display that is still connected: working on the first display, the next
  /// dictation pinned the pill to that display's edge nearest the second — a
  /// place the user never put it — and the drag could never stick.
  public static func visibleFrame(
    for customOrigin: CGPoint?,
    panelSize: CGSize,
    among visibleFrames: [CGRect],
    fallback: CGRect
  ) -> CGRect {
    guard let customOrigin else {
      return fallback
    }
    let panel = CGRect(origin: customOrigin, size: panelSize)
    var best: (frame: CGRect, area: CGFloat)?
    for frame in visibleFrames {
      let overlap = frame.intersection(panel)
      let area = overlap.isNull ? 0 : overlap.width * overlap.height
      if area > (best?.area ?? 0) {
        best = (frame: frame, area: area)
      }
    }
    return best?.frame ?? fallback
  }

  /// Resolves the panel's origin: the user's dragged `customOrigin` clamped
  /// fully back onto the current screen, or — when the pill has never been
  /// moved — the default placement, horizontally centered with its bottom edge
  /// `bottomOffset` above the visible frame's bottom. Clamping matters because
  /// a stored origin can be stale (saved on a monitor that has since been
  /// unplugged, or near an edge of a larger screen): it must never leave the
  /// pill stranded off-screen and invisible.
  public static func origin(
    panelSize: CGSize,
    visibleFrame: CGRect,
    customOrigin: CGPoint?,
    bottomOffset: CGFloat
  ) -> CGPoint {
    guard let customOrigin else {
      return CGPoint(
        x: visibleFrame.midX - panelSize.width / 2,
        y: visibleFrame.minY + bottomOffset
      )
    }
    return clamped(origin: customOrigin, size: panelSize, into: visibleFrame)
  }

  /// Clamps `origin` so a `size`-sized panel lies entirely inside `rect`. In
  /// the degenerate case of a panel larger than `rect` (impossible for the
  /// pill in practice) the max edge wins: the panel's top/right edge pins to
  /// the rect's and the overflow spills past the min edge — deterministic
  /// rather than oscillating between the two constraints.
  public static func clamped(origin: CGPoint, size: CGSize, into rect: CGRect) -> CGPoint {
    let maxX = rect.maxX - size.width
    let maxY = rect.maxY - size.height
    return CGPoint(
      x: min(max(origin.x, rect.minX), maxX),
      y: min(max(origin.y, rect.minY), maxY)
    )
  }
}

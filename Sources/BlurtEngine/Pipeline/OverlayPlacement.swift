import CoreGraphics

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
      bottomOffset: defaultBottomClearance - shadowMargin)
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
        y: visibleFrame.minY + bottomOffset)
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
      y: min(max(origin.y, rect.minY), maxY))
  }
}

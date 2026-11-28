import CoreGraphics
import Testing

@testable import BlurtEngine

/// Which screen the overlay pill goes on (`OverlayPlacement.visibleFrame`): the
/// one a dragged origin is on while it's still connected, else the active one.
@Suite("OverlayPlacement screen choice")
struct OverlayPlacementScreenTests {
  /// The active display, and a second one to its right.
  private let main = CGRect(x: 0, y: 0, width: 1_000, height: 600)
  private let second = CGRect(x: 1_000, y: 0, width: 1_200, height: 800)
  private let panel = CGSize(width: 200, height: 60)

  @Test("a pill dragged onto a connected second display stays there")
  func draggedOntoSecondDisplayStays() {
    let dragged = CGPoint(x: 1_500, y: 300)
    let frame = OverlayPlacement.visibleFrame(
      for: dragged, panelSize: panel, among: [main, second], fallback: main
    )
    #expect(frame == second)
    // And so the placement honours the drag, rather than pinning the pill to
    // the active display's right edge (x: 800).
    let origin = OverlayPlacement.panelOrigin(
      panelSize: panel, visibleFrame: frame, customOrigin: dragged, shadowMargin: 28
    )
    #expect(origin == dragged)
  }

  @Test("a panel straddling two displays goes on the one holding most of it")
  func straddlingPanelPicksTheLargerShare() {
    let frame = OverlayPlacement.visibleFrame(
      for: CGPoint(x: 950, y: 300), panelSize: panel, among: [main, second], fallback: main
    )
    #expect(frame == second)
  }

  @Test("the display holding most of the panel is measured by area, not by its overlap's shape")
  func largerShareIsByArea() {
    // 40×40 (1 600 pt²) on the left one, a wider but shorter 60×20 (1 200 pt²)
    // on the right one.
    let left = CGRect(x: 0, y: 0, width: 140, height: 1_000)
    let right = CGRect(x: 140, y: 120, width: 1_000, height: 1_000)
    let frame = OverlayPlacement.visibleFrame(
      for: CGPoint(x: 100, y: 100), panelSize: CGSize(width: 100, height: 40), among: [left, right], fallback: right
    )
    #expect(frame == left)
  }

  @Test("an origin on no connected display falls back to the active one")
  func staleOriginFallsBack() {
    let frame = OverlayPlacement.visibleFrame(
      for: CGPoint(x: 5_000, y: 5_000), panelSize: panel, among: [main, second], fallback: main
    )
    #expect(frame == main)
  }

  @Test("no dragged origin: the pill follows the active display")
  func noOriginFollowsTheActiveDisplay() {
    let frame = OverlayPlacement.visibleFrame(for: nil, panelSize: panel, among: [main, second], fallback: second)
    #expect(frame == second)
  }

  @Test("a panel only touching a display's edge isn't on it")
  func edgeContactIsNotOverlap() {
    let frame = OverlayPlacement.visibleFrame(
      for: CGPoint(x: 2_200, y: 300), panelSize: panel, among: [main, second], fallback: main
    )
    #expect(frame == main)
  }
}

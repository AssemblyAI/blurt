import Foundation
import Testing

@testable import BlurtEngine

/// The overlay pill's placement rules: default bottom-center, and a persisted
/// drag origin clamped fully back onto the current screen. The clamp is the
/// load-bearing part — a stored origin can be stale (saved on a monitor that's
/// since been unplugged) and must never leave the pill invisible off-screen.
@Suite("OverlayPlacement")
struct OverlayPlacementTests {
  private let screen = CGRect(x: 0, y: 0, width: 1000, height: 600)
  private let panel = CGSize(width: 200, height: 60)

  @Test("no custom origin: horizontally centered, bottomOffset above the bottom")
  func defaultPlacement() {
    let origin = OverlayPlacement.origin(
      panelSize: panel, visibleFrame: screen, customOrigin: nil, bottomOffset: 64)
    #expect(origin == CGPoint(x: 400, y: 64))
  }

  @Test("the default respects a non-zero visible-frame origin (Dock/menu bar insets)")
  func defaultPlacementOnInsetScreen() {
    let inset = CGRect(x: 100, y: 50, width: 800, height: 500)
    let origin = OverlayPlacement.origin(
      panelSize: panel, visibleFrame: inset, customOrigin: nil, bottomOffset: 64)
    #expect(origin == CGPoint(x: 400, y: 114))
  }

  @Test("an on-screen custom origin is used as-is")
  func onScreenCustomOriginUnchanged() {
    let custom = CGPoint(x: 300, y: 200)
    let origin = OverlayPlacement.origin(
      panelSize: panel, visibleFrame: screen, customOrigin: custom, bottomOffset: 64)
    #expect(origin == custom)
  }

  @Test("a stale origin past the top-right clamps the panel fully back on screen")
  func staleOriginClampsToMaxCorner() {
    // E.g. saved on a larger external monitor that's since been unplugged.
    let origin = OverlayPlacement.origin(
      panelSize: panel, visibleFrame: screen, customOrigin: CGPoint(x: 2400, y: 1300),
      bottomOffset: 64)
    #expect(origin == CGPoint(x: 800, y: 540))  // maxX - width, maxY - height
  }

  @Test("a stale origin past the bottom-left clamps to the visible frame's min corner")
  func staleOriginClampsToMinCorner() {
    let inset = CGRect(x: 100, y: 50, width: 800, height: 500)
    let origin = OverlayPlacement.origin(
      panelSize: panel, visibleFrame: inset, customOrigin: CGPoint(x: -500, y: -500),
      bottomOffset: 64)
    #expect(origin == CGPoint(x: 100, y: 50))
  }

  @Test("a barely-off-screen origin only moves along the offending axis")
  func clampIsPerAxis() {
    let origin = OverlayPlacement.origin(
      panelSize: panel, visibleFrame: screen, customOrigin: CGPoint(x: 900, y: 200),
      bottomOffset: 64)
    #expect(origin == CGPoint(x: 800, y: 200))
  }

  @Test("a panel larger than the screen pins deterministically to the max edge")
  func oversizedPanelPinsToMaxEdge() {
    // Impossible for the pill in practice, but the degenerate case must stay
    // deterministic rather than oscillate between the two constraints.
    let tiny = CGRect(x: 0, y: 0, width: 100, height: 40)
    let clamped = OverlayPlacement.clamped(
      origin: CGPoint(x: 50, y: 20), size: panel, into: tiny)
    #expect(clamped == CGPoint(x: -100, y: -20))  // maxX - width, maxY - height
  }
}

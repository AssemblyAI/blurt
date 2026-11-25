import CoreGraphics
import Foundation
import Testing

@testable import BlurtEngine

@Suite("WindowOrder")
struct WindowOrderTests {
  @Test("an app is in front when its window is the top normal one, panels and the menu bar aside")
  func windowOrder() {
    let menuBar = WindowOrder.Window(owner: 1, layer: 24)
    let pill = WindowOrder.Window(owner: 9, layer: 3)
    #expect(WindowOrder.isFrontmost(5, in: [menuBar, pill, .init(owner: 5, layer: 0), .init(owner: 6, layer: 0)]))
    #expect(!WindowOrder.isFrontmost(5, in: [menuBar, .init(owner: 6, layer: 0), .init(owner: 5, layer: 0)]))
    // Whose window a click lands in: the top normal-layer window there,
    // whatever floats above it.
    let spot = CGPoint(x: 100, y: 100)
    let music = WindowOrder.Window(owner: 5, layer: 0, bounds: CGRect(x: 0, y: 0, width: 800, height: 600))
    let code = WindowOrder.Window(owner: 6, layer: 0, bounds: CGRect(x: 50, y: 50, width: 200, height: 200))
    #expect(WindowOrder.owner(at: spot, in: [menuBar, code, music]) == 6)
    #expect(WindowOrder.owner(at: CGPoint(x: 700, y: 500), in: [menuBar, code, music]) == 5)
    #expect(WindowOrder.owner(at: CGPoint(x: 900, y: 900), in: [code, music]) == nil)
    // No window of its own on screen: nothing to wait for.
    #expect(WindowOrder.isFrontmost(5, in: [menuBar, .init(owner: 6, layer: 0)]))
  }
}

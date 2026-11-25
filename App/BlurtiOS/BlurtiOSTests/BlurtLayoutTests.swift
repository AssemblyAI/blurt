import BlurtDesign
import Foundation
import KeyboardKit
import Testing

@testable import BlurtiOS

/// Blurt's layout against KeyboardKit's own: Apple's keyboard with the mic
/// after space in the bottom row, at the small key's size, and nothing else
/// moved (`KeyboardLayout.blurt`).
@Suite("Blurt's layout is Apple's with the mic in it")
struct BlurtLayoutTests {
  /// A context on the page named, with or without the globe in the row.
  private static func context(_ type: Keyboard.KeyboardType, globe: Bool) -> KeyboardContext {
    let context = KeyboardContext(settings: KeyboardSettings())
    context.keyboardType = type
    context.needsInputModeSwitchKey = globe
    return context
  }

  /// The bottom row's actions, the emoji switch aside: KeyboardKit adds it
  /// or not by its own settings, and the mic's place is the same either way.
  private static func bottomActions(_ layout: KeyboardLayout) -> [KeyboardAction] {
    (layout.itemRows.last ?? []).map(\.action).filter { $0 != .keyboardType(.emojis) }
  }

  private static func isReturn(_ action: KeyboardAction?) -> Bool {
    if case .primary? = action {
      return true
    }
    return false
  }

  @Test(
    "the bottom row is 123 · globe? · space · mic · return on the letters, and ABC leads it on the symbol pages",
    arguments: [Keyboard.KeyboardType.alphabetic, .numeric, .symbolic], [false, true])
  func bottomRow(type: Keyboard.KeyboardType, globe: Bool) throws {
    let context = Self.context(type, globe: globe)
    let standard = KeyboardLayout.standard(for: context)
    let layout = KeyboardLayout.blurt(for: context)
    let bottom = try #require(layout.itemRows.last)
    let page = KeyboardAction.keyboardType(type == .alphabetic ? .numeric : .alphabetic)
    let actions = Self.bottomActions(layout)
    #expect(Array(actions.dropLast()) == [page] + (globe ? [.nextKeyboard] : []) + [.space, .blurtMic], "\(actions)")
    #expect(Self.isReturn(actions.last), "\(actions)")
    // Apple's row with the mic after space and nothing else moved; every
    // other row is KeyboardKit's own, key for key.
    var apple = try #require(standard.itemRows.last).map(\.action)
    apple.insert(.blurtMic, at: try #require(apple.firstIndex(of: .space)) + 1)
    #expect(bottom.map(\.action) == apple)
    #expect(
      layout.itemRows.dropLast().map { $0.map(\.action) } == standard.itemRows.dropLast().map { $0.map(\.action) })
    // Every cell at Apple's measured geometry (`KeyboardLayoutConfiguration.blurt`).
    let configuration = KeyboardLayoutConfiguration.blurt
    #expect(layout.configuration == configuration)
    for item in layout.itemRows.joined() {
      #expect(item.size.height == configuration.rowHeight)
      #expect(item.edgeInsets == configuration.buttonInsets)
    }
    // The mic at the 123 key's size, and both at Apple's measured width (the
    // cap and the gap), so every cap keeps Apple's width.
    let mic = try #require(bottom.first { $0.action == .blurtMic })
    #expect(mic.size == bottom.first?.size)
    #expect(mic.size.width == .points(DesignTokens.Metrics.keyAbcWidth402 + DesignTokens.Metrics.keyGap))
  }

  // KeyboardKit draws the number pad as its own view (`Keyboard.NumberPad`),
  // not from the layout: for that type its layout service still hands back
  // the letters' rows, space bar and all, so `KeyboardLayout.blurt` keeps the
  // mic out of them by the type, not the row.
  @Test("the number pad gets no mic: KeyboardKit draws it from no rows, and Apple's has none")
  func numberPad() {
    let context = Self.context(.numberPad, globe: true)
    let layout = KeyboardLayout.blurt(for: context)
    #expect(!layout.itemRows.joined().contains { $0.action == .blurtMic })
    #expect(
      layout.itemRows.map { $0.map(\.action) }
        == KeyboardLayout.standard(for: context).itemRows.map { $0.map(\.action) })
    #expect(layout.configuration == .blurt)
  }

  @Test("the bar and the margins make Apple's band above the keys and Apple's keyboard height")
  func bands() throws {
    let glass = try AppleGeometry.load("apple-geometry-glass-402")
    let band = DesignTokens.Metrics.voicebarHeight + DesignTokens.Metrics.marginVertical
    #expect(abs(band - CGFloat(glass.cap["topBand"] ?? 0)) < 0.001)
    let rows = 4 * DesignTokens.Metrics.keyHeight + 3 * DesignTokens.Metrics.rowGap
    let height = band + rows + DesignTokens.Metrics.marginBottomKeys
    #expect(abs(height - CGFloat(glass.cap["keyboardHeight"] ?? 0)) < 0.001)
  }

  @Test("the mic goes in once: a second pass over the same context adds no second")
  func once() {
    let context = Self.context(.alphabetic, globe: true)
    for _ in 0..<2 {
      let mics = KeyboardLayout.blurt(for: context).itemRows.joined().filter { $0.action == .blurtMic }
      #expect(mics.count == 1)
    }
  }
}

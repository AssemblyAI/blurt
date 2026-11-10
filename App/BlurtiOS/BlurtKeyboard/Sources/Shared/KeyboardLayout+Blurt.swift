import BlurtDesign
import KeyboardKit
import SwiftUI

extension KeyboardAction {
  /// The mic key: Blurt's one action of its own on Apple's keyboard, handled
  /// by `BlurtActionHandler` and drawn by `MicKey`.
  static let blurtMic = KeyboardAction.custom(named: "blurt-mic")
}

extension KeyboardLayoutConfiguration {
  /// Apple's keyboard's own numbers, as the probe measured them off the
  /// iPhone (`Design/apple-geometry-*.json`, DESIGN.md › Apple's geometry),
  /// in KeyboardKit's terms: a row is a cap and the gap under it, a cell is
  /// the cap and half a gap each side, and the keyboard's edges are what is
  /// left of the margins past those half gaps. `scripts/keyboard-parity.sh`
  /// reads the result back against Apple's keyboard on the same simulator.
  static let blurt = KeyboardLayoutConfiguration(
    edgeInsets: EdgeInsets(
      top: DesignTokens.Metrics.marginVertical - DesignTokens.Metrics.rowGap / 2,
      leading: DesignTokens.Metrics.marginSide - DesignTokens.Metrics.keyGap / 2,
      bottom: DesignTokens.Metrics.marginBottomKeys - DesignTokens.Metrics.rowGap / 2,
      trailing: DesignTokens.Metrics.marginSide - DesignTokens.Metrics.keyGap / 2),
    buttonCornerRadius: DesignTokens.Metrics.keyRadius,
    buttonInsets: EdgeInsets(
      top: DesignTokens.Metrics.rowGap / 2, leading: DesignTokens.Metrics.keyGap / 2,
      bottom: DesignTokens.Metrics.rowGap / 2, trailing: DesignTokens.Metrics.keyGap / 2),
    rowHeight: DesignTokens.Metrics.keyHeight + DesignTokens.Metrics.rowGap)
}

extension KeyboardLayout {
  /// Apple's layout with the mic in it, at Apple's measured geometry. Apple's
  /// dictation mic on a Face ID phone sits in the host's bar under the
  /// keyboard, which no extension can draw into (DESIGN.md › The mic's
  /// place), so the mic takes the small key's place on the other side of
  /// space: `123 | space | mic | return`, at the 123 key's own size, so every
  /// cap keeps Apple's width — and, on a phone with the globe in the row, the
  /// five keys Apple's own row has there. Only rows that have a space bar,
  /// and never for the number pad — KeyboardKit draws that one from no rows
  /// at all (`Keyboard.NumberPad`), and Apple's has no mic.
  static func blurt(for context: KeyboardContext) -> KeyboardLayout {
    let standard = KeyboardLayout.standard(for: context)
    let configuration = KeyboardLayoutConfiguration.blurt
    // The standard rows at Apple's cell height and insets, under Apple's
    // edges: the configuration a layout is built with is what its items carry.
    var layout = KeyboardLayout(
      itemRows: standard.itemRows.map { row in
        row.map { item in
          var item = item
          item.size.height = configuration.rowHeight
          item.edgeInsets = configuration.buttonInsets
          return item
        }
      }, configuration: configuration)
    guard context.keyboardType != .numberPad, let bottom = layout.itemRows.last,
      bottom.contains(where: { $0.action == .space }),
      !bottom.contains(where: { $0.action == .blurtMic }), let small = bottom.first
    else { return layout }
    // The 123 key, and the mic beside space, at Apple's measured width
    // (`key/abc-width-402`, scaled with the keyboard as Apple's scales): a
    // cell is the cap and the gap. KeyboardKit's own small keys are a share
    // of the row, which the measured edges leave a hair narrower.
    let width = context.screenSize?.width ?? DesignTokens.Metrics.keyReferenceWidth
    let cell = KeyboardLayoutItem.Width.points(
      DesignTokens.Metrics.keyAbcWidth402 * width / DesignTokens.Metrics.keyReferenceWidth
        + DesignTokens.Metrics.keyGap)
    var size = small.size
    size.width = cell
    layout.itemRows[layout.itemRows.count - 1][0].size = size
    let mic = KeyboardLayoutItem(action: .blurtMic, size: size, edgeInsets: small.edgeInsets)
    layout.itemRows.insert(mic, after: .space)
    return layout
  }
}

import KeyboardKit

extension KeyboardAction {
  /// The mic key: Blurt's one action of its own on Apple's keyboard, handled
  /// by `BlurtActionHandler` and drawn by `MicKey`.
  static let blurtMic = KeyboardAction.custom(named: "blurt-mic")
}

extension KeyboardLayout {
  /// Apple's layout with the mic in it. Apple's dictation mic on a Face ID
  /// phone sits in the host's bar under the keyboard, which no extension can
  /// draw into (DESIGN.md › The mic's place), so the mic takes the small
  /// key's place on the other side of space: `123 | space | mic | return`,
  /// at the 123 key's own size, so every cap keeps Apple's width — and, on a
  /// phone with the globe in the row, the five keys Apple's own row has
  /// there. Only rows that have a space bar, and never for the number pad —
  /// KeyboardKit draws that one from no rows at all (`Keyboard.NumberPad`),
  /// and Apple's has no mic.
  static func blurt(for context: KeyboardContext) -> KeyboardLayout {
    var layout = KeyboardLayout.standard(for: context)
    guard context.keyboardType != .numberPad, let bottom = layout.itemRows.last,
      bottom.contains(where: { $0.action == .space }),
      !bottom.contains(where: { $0.action == .blurtMic }), let small = bottom.first
    else { return layout }
    let mic = KeyboardLayoutItem(action: .blurtMic, size: small.size, edgeInsets: small.edgeInsets)
    layout.itemRows.insert(mic, after: .space)
    return layout
  }
}

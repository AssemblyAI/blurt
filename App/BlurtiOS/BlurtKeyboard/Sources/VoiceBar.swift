import BlurtDesign
import BlurtiOSCore
import SwiftUI
import UIKit

/// The keyboard's voice row, and the only place voice lives in the bar and
/// the full keyboard: the mic key — tap to start and stop, hold to talk —
/// with the small + beside it for the one thing people want the instant
/// Blurt mishears a word: add it as a key term. The row is `VoiceRow`;
/// `VoiceRowHost` swaps it for the key-term field the keys type into, or for
/// the one note the element can't carry (no Full Access), and puts the
/// status line under it — on the row's bottom text line, the row drawn in
/// the band above. `addCap` is the most the add key may take where keys
/// share the row (the slim bar).
struct VoiceBar: View {
  var model: KeyboardModel
  var addCap: CGFloat?

  static let height = DesignTokens.Metrics.voicebarHeight
  /// The status line's height: one text line at `size/line` in the system
  /// face, what the line takes off the row when it shows here. The row is
  /// the band above it, and `SessionContractNumbersTests` holds that band to
  /// the grille's height (DESIGN.md › The two processes: the line's place).
  static var lineHeight: CGFloat { UIFont.systemFont(ofSize: DesignTokens.Typography.sizeLine).lineHeight }

  var body: some View {
    VoiceRowHost(model: model, slot: .bar, rowHeight: Self.height) { height in
      VoiceRow(model: model, slot: .bar, height: height, addCap: addCap)
    }
    .frame(maxWidth: .infinity)
    .frame(height: Self.height)
  }
}

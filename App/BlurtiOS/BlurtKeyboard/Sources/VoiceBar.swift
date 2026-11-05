import BlurtDesign
import BlurtiOSCore
import SwiftUI

/// The keyboard's voice row, and the only place voice lives in the bar and
/// the full keyboard: the mic key — tap to start and stop, hold to talk —
/// with the small + beside it for the one thing people want the instant
/// Blurt mishears a word: add it as a key term. The row is `VoiceRow`;
/// `VoiceRowHost` swaps it for the key-term field the keys type into, or for
/// the one note the element can't carry (no Full Access), and puts the
/// status line under it. `addCap` is the most the add key may take where
/// keys share the row (the slim bar).
struct VoiceBar: View {
  var model: KeyboardModel
  var addCap: CGFloat?

  static let height = DesignTokens.Metrics.voicebarHeight

  var body: some View {
    VoiceRowHost(model: model, slot: .bar) {
      VoiceRow(model: model, slot: .bar, height: Self.height, addCap: addCap)
    }
    .frame(maxWidth: .infinity)
    .frame(height: Self.height)
  }
}

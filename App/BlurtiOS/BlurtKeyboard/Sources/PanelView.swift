import SwiftUI

/// The voice element, centred, big; cancel in the corner while something is
/// in flight; one row of keys. 216 pt.
struct PanelView: View {
  var model: KeyboardModel
  @Environment(\.keyboardPalette) private var palette

  var body: some View {
    VStack(spacing: DesignTokens.Metrics.panelSpacing) {
      Spacer(minLength: 0)
      MicControl(model: model, slot: .panel)
      Spacer(minLength: 0)
      HStack(spacing: KeyboardPalette.keyGap) {
        if model.needsGlobe { KeyCap(systemImage: "globe", dark: true) { model.globe() } }
        KeyCap(title: "space", flexible: true) { model.space() }
        KeyCap(systemImage: "delete.left", dark: true) { model.deleteBackward() }
        KeyCap(title: model.returnLabel ?? "return", dark: true) { model.newline() }
      }
    }
    .overlay(alignment: .topTrailing) {
      if model.voiceState.canCancel {
        KeyCap(systemImage: "xmark", tint: palette.notice, bare: true) { model.cancel() }
          .accessibilityLabel("Cancel dictation")
          .transition(.opacity)
      }
    }
    .overlay(alignment: .topLeading) {
      // The +, or the chip for a highlighted word, growing from the corner
      // and never as far as the cancel × in the other one.
      AddTermKey(model: model, maxWidth: DesignTokens.Metrics.addtermChipMaxWidth)
        .padding(DesignTokens.Metrics.addtermInset)
    }
  }
}

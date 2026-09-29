import SwiftUI

/// A big orb, centred, that dissipates into the wave while recording; cancel
/// in the corner while something is in flight; one row of keys. 216 pt.
struct PanelView: View {
  var model: KeyboardModel

  var body: some View {
    VStack(spacing: DesignTokens.Metrics.panelSpacing) {
      Spacer(minLength: 0)
      MicControl(
        model: model, size: DesignTokens.Metrics.orbPanel,
        wave: CGSize(width: DesignTokens.Metrics.wavePanelWidth, height: DesignTokens.Metrics.wavePanelHeight))
      Spacer(minLength: 0)
      HStack(spacing: KeyboardPalette.keyGap) {
        if model.needsGlobe { KeyCap(systemImage: "globe", dark: true) { model.globe() } }
        KeyCap(title: "space", flexible: true) { model.space() }
        KeyCap(systemImage: "delete.left", dark: true) { model.deleteBackward() }
        KeyCap(systemImage: "return", dark: true) { model.newline() }
      }
    }
    .overlay(alignment: .topTrailing) {
      if model.voiceState.canCancel {
        KeyCap(systemImage: "xmark", tint: BlurtBrand.errorOrange, bare: true) { model.cancel() }
          .accessibilityLabel("Cancel dictation")
          .transition(.opacity)
      }
    }
    .overlay(alignment: .topLeading) { AddTermKey(model: model).padding(DesignTokens.Metrics.addtermInset) }
  }
}

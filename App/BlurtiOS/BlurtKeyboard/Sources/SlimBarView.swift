import SwiftUI

/// One row: the globe, the voice bar, delete and return. 60 pt.
struct SlimBarView: View {
  var model: KeyboardModel

  var body: some View {
    HStack(spacing: DesignTokens.Metrics.slimSpacing) {
      if model.needsGlobe { KeyCap(systemImage: "globe", dark: true) { model.globe() } }
      VoiceBar(model: model)
      KeyCap(systemImage: "delete.left", dark: true) { model.deleteBackward() }
      KeyCap(title: model.returnLabel ?? "return", dark: true) { model.newline() }
    }
  }
}

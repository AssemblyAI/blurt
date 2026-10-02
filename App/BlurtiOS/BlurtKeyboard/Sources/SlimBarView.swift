import BlurtiOSCore
import SwiftUI

/// One row: the globe (when the phone doesn't draw its own), the voice bar,
/// delete and return, at the full keyboard's key widths and gap. 60 pt.
struct SlimBarView: View {
  var model: KeyboardModel

  var body: some View {
    GeometryReader { geo in
      let geometry = KeyGeometry(rowWidth: geo.size.width)
      // The keys are as tall as the row, so nothing sits half a point off.
      let height = VoiceBar.height
      HStack(spacing: geometry.gap) {
        if model.needsGlobe {
          KeyCap(systemImage: "globe", dark: true, width: geometry.abcWidth, height: height) { model.globe() }
        }
        VoiceBar(model: model)
        KeyCap(systemImage: "delete.left", dark: true, width: geometry.abcWidth, height: height) {
          model.deleteBackward()
        }
        KeyCap(title: model.returnLabel ?? "return", dark: true, width: geometry.returnWidth, height: height) {
          model.newline()
        }
      }
    }
    .frame(height: VoiceBar.height)
  }
}

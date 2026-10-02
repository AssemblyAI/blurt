import BlurtiOSCore
import SwiftUI

/// The voice element, big, dead centre — or at the edge Settings chose — with
/// the + beside it and cancel × on its other side while something is in
/// flight; one row of keys at the iPhone's widths. 216 pt.
struct PanelView: View {
  var model: KeyboardModel
  @Environment(\.keyboardPalette) private var palette
  @Environment(\.layoutDirection) private var direction

  var body: some View {
    GeometryReader { geo in
      let geometry = KeyGeometry(rowWidth: geo.size.width)
      let alignment = model.micAlignment.alignment(in: direction)
      let atEdge = alignment != .center
      VStack(spacing: DesignTokens.Metrics.panelSpacing) {
        // The row takes all the height above the keys. The spacing under it
        // is the margin above the page, so the mic is centred between the
        // keyboard's top edge and the keys.
        VoiceRow(model: model, slot: .panel, height: VoiceSlot.panel.box.height, cancels: !atEdge)
          .frame(maxHeight: .infinity)
        // The stock bottom row at the full keyboard's widths, so nothing
        // changes size when the carousel flips to the keys and back.
        HStack(spacing: geometry.gap) {
          if model.needsGlobe {
            KeyCap(systemImage: "globe", dark: true, width: geometry.abcWidth) { model.globe() }
          }
          KeyCap(title: "space", flexible: true) { model.space() }
          KeyCap(systemImage: "delete.left", dark: true, width: geometry.abcWidth) { model.deleteBackward() }
          KeyCap(title: model.returnLabel ?? "return", dark: true, width: geometry.returnWidth) { model.newline() }
        }
      }
      .overlay(alignment: alignment == .trailing ? .topLeading : .topTrailing) {
        // With the mic at an edge, cancel goes to the far corner, clear of
        // the mic and the + on its inner side.
        if atEdge, model.voiceState.canCancel {
          GlyphKey(symbol: "xmark", tint: palette.notice, label: "Cancel dictation") { model.cancel() }
            .padding(DesignTokens.Metrics.addtermInset)
            .transition(.opacity)
        }
      }
      .animation(.easeInOut(duration: DesignTokens.Motion.stateFade), value: model.voiceState.canCancel)
    }
  }
}

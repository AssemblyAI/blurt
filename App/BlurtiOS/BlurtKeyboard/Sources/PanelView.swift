import SwiftUI

/// The voice element, centred, big; cancel in the corner while something is
/// in flight; one row of keys. 216 pt.
struct PanelView: View {
  var model: KeyboardModel
  @Environment(\.keyboardPalette) private var palette
  @Environment(\.voiceElementKind) private var kind
  @Environment(\.layoutDirection) private var direction

  var body: some View {
    let alignment = model.micAlignment.alignment(in: direction)
    let atEdge = alignment != .center
    let plusLeads = model.micAlignment.plusLeads(in: direction)
    let recording = model.voiceState.isRecording
    // In the middle the element has its whole slot and the + its corner. At
    // an edge (one hand) the panel is a big voice bar: the key is as wide as
    // the element shows, so the element itself — not an empty half of its
    // box — is what sits under the thumb, the + beside it on its inner side,
    // and cancel in the far corner, clear of them both.
    let width = atEdge ? max(kind.visibleWidth(slot: .panel, recording: recording), DesignTokens.Metrics.keyMinWidth) : nil
    VStack(spacing: DesignTokens.Metrics.panelSpacing) {
      Spacer(minLength: 0)
      HStack(spacing: DesignTokens.Metrics.voicebarAddtermClearance) {
        if atEdge, plusLeads { AddTermKey(model: model) }
        MicControl(model: model, slot: .panel, width: width)
        if atEdge, !plusLeads { AddTermKey(model: model) }
      }
      .frame(maxWidth: .infinity, alignment: alignment)
      .animation(.easeInOut(duration: DesignTokens.Motion.waveFade), value: recording)
      Spacer(minLength: 0)
      HStack(spacing: KeyboardPalette.keyGap) {
        if model.needsGlobe { KeyCap(systemImage: "globe", dark: true) { model.globe() } }
        KeyCap(title: "space", flexible: true) { model.space() }
        KeyCap(systemImage: "delete.left", dark: true) { model.deleteBackward() }
        KeyCap(title: model.returnLabel ?? "return", dark: true) { model.newline() }
      }
    }
    .overlay(alignment: alignment == .trailing ? .topLeading : .topTrailing) {
      if model.voiceState.canCancel {
        KeyCap(systemImage: "xmark", tint: palette.notice, bare: true) { model.cancel() }
          .accessibilityLabel("Cancel dictation")
          .transition(.opacity)
      }
    }
    .overlay(alignment: .topLeading) {
      // The +, or the chip for a highlighted word, growing from the corner
      // and never as far as the cancel × in the other one.
      if !atEdge {
        AddTermKey(model: model, maxWidth: DesignTokens.Metrics.addtermChipMaxWidth)
          .padding(DesignTokens.Metrics.addtermInset)
      }
    }
  }
}

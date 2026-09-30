import SwiftUI

/// Pick a keyboard theme from live previews: a card per theme, each the real
/// keyboard drawn small in both of its faces — the light one the keyboard
/// shows over a light app, the dark one over a dark app — the chosen theme
/// ringed in the accent. One theme for now; the curated ones return through
/// `KeyboardPalette.all`. The keyboard picks the choice up the next time it
/// comes up.
struct ThemePickerView: View {
  @State private var chosen = KeyboardPalette.resolve(SharedStore.themeID, dark: false).id

  var body: some View {
    ScrollView {
      VStack(spacing: DesignTokens.Metrics.appStackGap) {
        ForEach(KeyboardPalette.all) { palette in
          ThemeCard(palette: palette, chosen: palette.id == chosen) {
            chosen = palette.id
            SharedStore.themeID = palette.id
          }
        }
      }
      .padding(DesignTokens.Metrics.appPagePad)
    }
    .page()
    .navigationTitle("Theme")
    .navigationBarTitleDisplayMode(.inline)
  }
}

private struct ThemeCard: View {
  let palette: KeyboardPalette
  let chosen: Bool
  let pick: () -> Void

  /// The preview keyboard is the full layout, drawn at the reference width
  /// and scaled down to fit the card.
  private static let previewWidth = DesignTokens.Metrics.pickerPreviewWidth
  private static let scale = DesignTokens.Metrics.pickerScale

  var body: some View {
    Button(action: pick) {
      VStack(alignment: .leading, spacing: DesignTokens.Metrics.appStackGap) {
        HStack(spacing: DesignTokens.Metrics.appPreviewGap) {
          preview(KeyboardPalette.resolve(palette.id, dark: false))
          preview(KeyboardPalette.resolve(palette.id, dark: true))
        }
        VStack(alignment: .leading, spacing: DesignTokens.Metrics.appLineGap) {
          Text(palette.name).font(BlurtType.body(DesignTokens.Typography.sizeBody, bold: true)).foregroundStyle(
            BlurtBrand.text)
          Text(palette.vibe).font(BlurtType.body(DesignTokens.Typography.sizeCaption)).foregroundStyle(BlurtBrand.muted)
        }
      }
      .padding(DesignTokens.Metrics.appCardPad)
      .frame(maxWidth: .infinity, alignment: .leading)
      .card()
      .overlay(
        RoundedRectangle(cornerRadius: DesignTokens.Metrics.cardRadius)
          .strokeBorder(chosen ? BlurtBrand.accent : Color.clear, lineWidth: DesignTokens.Metrics.cardBorder))
    }
    .buttonStyle(.plain)
    .accessibilityLabel(palette.name)
    .accessibilityAddTraits(chosen ? .isSelected : [])
  }

  private func preview(_ face: KeyboardPalette) -> some View {
    KeyboardRootView(model: Self.model(for: face))
      .frame(width: Self.previewWidth, height: KeyboardLayout.full.height)
      .background(face.standIn)
      .scaleEffect(Self.scale, anchor: .topLeading)
      .frame(width: Self.previewWidth * Self.scale, height: KeyboardLayout.full.height * Self.scale)
      .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Metrics.pickerRadius))
      .allowsHitTesting(false)
  }

  private static func model(for palette: KeyboardPalette) -> KeyboardModel {
    let model = KeyboardModel()
    model.layout = .full
    model.hasFullAccess = true
    model.isListening = true
    model.needsGlobe = true
    model.paletteOverride = palette
    return model
  }
}

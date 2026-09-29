import SwiftUI

/// Pick a keyboard theme from live previews, Partiful-style: a grid of cards,
/// each the real keyboard drawn small in that theme, the chosen one ringed
/// in the accent. The keyboard picks it up the next time it comes up.
struct ThemePickerView: View {
  @State private var chosen = KeyboardPalette.resolve(SharedStore.themeID, dark: false).id
  @Environment(\.colorScheme) private var colorScheme

  private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

  var body: some View {
    ScrollView {
      LazyVGrid(columns: columns, spacing: 14) {
        ForEach(KeyboardPalette.all) { palette in
          // A theme has two faces; the card shows the one this screen is in,
          // which is the one the keyboard would show in an app that looks
          // like it.
          ThemeCard(
            palette: KeyboardPalette.resolve(palette.id, dark: colorScheme == .dark), chosen: palette.id == chosen
          ) {
            chosen = palette.id
            SharedStore.themeID = palette.id
          }
        }
      }
      .padding(20)
    }
    .background(Color(uiColor: .systemGroupedBackground))
    .navigationTitle("Theme")
    .navigationBarTitleDisplayMode(.inline)
  }
}

private struct ThemeCard: View {
  let palette: KeyboardPalette
  let chosen: Bool
  let pick: () -> Void

  /// The preview keyboard is the full layout, drawn at a phone's width and
  /// scaled down to fit two cards across.
  private static let previewWidth = DesignTokens.Metrics.pickerPreviewWidth
  private static let scale = DesignTokens.Metrics.pickerScale

  var body: some View {
    Button(action: pick) {
      VStack(alignment: .leading, spacing: 10) {
        KeyboardRootView(model: Self.model(for: palette))
          .frame(width: Self.previewWidth, height: KeyboardLayout.full.height)
          .scaleEffect(Self.scale, anchor: .topLeading)
          .frame(width: Self.previewWidth * Self.scale, height: KeyboardLayout.full.height * Self.scale)
          .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Metrics.pickerRadius))
          .allowsHitTesting(false)
        VStack(alignment: .leading, spacing: 2) {
          Text(palette.name).font(.headline)
          Text(palette.vibe).font(.caption).foregroundStyle(.secondary)
        }
      }
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .card()
      .overlay(
        RoundedRectangle(cornerRadius: DesignTokens.Metrics.cardRadius)
          .strokeBorder(chosen ? BlurtBrand.accent : Color.clear, lineWidth: 2))
    }
    .buttonStyle(.plain)
    .accessibilityLabel(palette.name)
    .accessibilityAddTraits(chosen ? .isSelected : [])
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

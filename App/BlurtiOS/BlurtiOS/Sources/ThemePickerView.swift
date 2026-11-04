import BlurtDesign
import BlurtiOSCore
import SwiftUI

/// Pick a keyboard theme from live previews: a card per theme, each the real
/// keyboard drawn small in both of its faces — the light one the keyboard
/// shows over a light app, the dark one over a dark app — the chosen theme
/// ringed in the accent. The list is this OS generation's
/// (`KeyboardPalette.all(for:)`): the brand, and on the classic generation
/// the iPhone's own keys first; the curated ones return through the same
/// list. The keyboard picks the choice up the next time it comes up.
struct ThemePickerView: View {
  /// The generation this phone draws, so the picker offers what the
  /// keyboard will show (`KeyboardProfile.standIn`).
  private static let profile = KeyboardProfile.standIn(width: DesignTokens.Metrics.pickerPreviewWidth)

  @State private var chosen = KeyboardPalette.resolve(
    SharedStore.themeID, dark: false, generation: KeyboardProfile.standInGeneration
  ).id

  var body: some View {
    ScrollView {
      VStack(spacing: DesignTokens.Metrics.appStackGap) {
        ForEach(KeyboardPalette.all(for: Self.profile.generation)) { palette in
          ThemeCard(palette: palette, profile: Self.profile, chosen: palette.id == chosen) {
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
  let profile: KeyboardProfile
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
          preview(KeyboardPalette.resolve(palette.id, dark: false, generation: profile.generation))
          preview(KeyboardPalette.resolve(palette.id, dark: true, generation: profile.generation))
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
    let height = KeyboardLayout.full.height(profile: profile)
    return KeyboardRootView(model: Self.model(for: face), profile: profile)
      .frame(width: Self.previewWidth, height: height)
      .background(face.standIn(painted: profile.paintsSurface))
      .scaleEffect(Self.scale, anchor: .topLeading)
      .frame(width: Self.previewWidth * Self.scale, height: height * Self.scale)
      .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Metrics.pickerRadius))
      .allowsHitTesting(false)
  }

  private static func model(for palette: KeyboardPalette) -> KeyboardModel {
    let model = KeyboardModel()
    model.layout = .full
    model.hasFullAccess = true
    model.isListening = true
    model.needsGlobe = true
    model.faceOverride = ThemeFace(palette)
    return model
  }
}

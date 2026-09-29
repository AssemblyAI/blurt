import SwiftUI

/// The app's own additions to the brand: the appearance-adaptive pieces the
/// keyboard never needs, resolved from the asset catalog exactly as on the Mac
/// (`Assets.xcassets`, copied from `App/Blurt/Blurt/Assets.xcassets`).
extension BlurtBrand {
  /// `green` in light, `greenOnDark` in dark — the catalog's `AccentColor`,
  /// which is also the app-level accent (`project.yml`), so system-drawn
  /// chrome and our views agree.
  nonisolated static let accent = Color.accentColor
  /// The warm card the design draws its containers with: `#EBE8E8` on
  /// `#DEDBDB` in light, `#26231E` on `#3A362F` in dark.
  nonisolated static let cardFill = Color("CardFill")
  nonisolated static let cardBorder = Color("CardBorder")
}

extension View {
  /// The design's card: warm fill, 16 pt corners, a hairline border.
  func card() -> some View {
    background(BlurtBrand.cardFill, in: RoundedRectangle(cornerRadius: DesignTokens.Metrics.cardRadius))
      .overlay(
        RoundedRectangle(cornerRadius: DesignTokens.Metrics.cardRadius)
          .strokeBorder(BlurtBrand.cardBorder, lineWidth: DesignTokens.Metrics.cardBorder))
  }
}

/// The lowercase wordmark from the Mac's ready screen, tinted with the accent
/// (`blurt-ready-logo.png`, shared from `App/Blurt/Blurt/Branding`).
struct Wordmark: View {
  private static let height = DesignTokens.Metrics.wordmarkHeight

  var body: some View {
    if let image = UIImage(named: "blurt-ready-logo") {
      Image(uiImage: image)
        .renderingMode(.template)
        .resizable()
        .scaledToFit()
        .frame(height: Self.height)
        .foregroundStyle(BlurtBrand.accent)
        .accessibilityLabel("Blurt")
    } else {
      Text("blurt").font(.title2.weight(.bold)).foregroundStyle(BlurtBrand.accent)
    }
  }
}

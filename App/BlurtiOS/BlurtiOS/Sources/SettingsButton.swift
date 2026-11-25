import BlurtDesign
import SwiftUI

/// The gear in each tab's header, which opens Settings.
struct SettingsButton: View {
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: "gearshape")
        .font(.system(size: DesignTokens.Metrics.appIcon, weight: DesignTokens.Typography.weightGlyph))
        .foregroundStyle(BlurtBrand.muted)
    }
    .accessibilityLabel("Settings")
  }
}

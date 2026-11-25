import BlurtDesign
import SwiftUI

/// After the keyboard brought Blurt forward to start a session: points at
/// iOS's own back link, "◀ Notes" or whichever app it was, in place of the
/// clock at the top left — the one way back to the app the user was typing in
/// (an app can't return there itself).
struct ReturnHint: View {
  var body: some View {
    Label("To keep typing, tap “◀” with the app's name in the top-left corner.", systemImage: "arrow.up.left")
      .bodyFont(DesignTokens.Typography.sizeCaption, bold: true)
      .foregroundStyle(BlurtBrand.ctaText)
      .padding(DesignTokens.Metrics.appChipPadX)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(BlurtBrand.cta, in: RoundedRectangle(cornerRadius: DesignTokens.Metrics.radiusInput))
  }
}

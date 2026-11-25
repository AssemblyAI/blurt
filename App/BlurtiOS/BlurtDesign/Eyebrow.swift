import SwiftUI

/// An eyebrow: the system mono, uppercase, tracked, muted — the brand's
/// section label, above every group on a screen.
package struct Eyebrow: View {
  let text: String
  var color = BlurtBrand.muted

  package var body: some View {
    Text(text.uppercased())
      .font(BlurtType.mono(DesignTokens.Typography.sizeEyebrow, weight: .medium))
      .tracking(DesignTokens.Typography.trackingEyebrow)
      .foregroundStyle(color)
  }

  package init(_ text: String, color: Color = BlurtBrand.muted) {
    self.text = text
    self.color = color
  }
}

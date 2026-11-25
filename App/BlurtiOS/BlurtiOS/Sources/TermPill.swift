import AssemblyAI
import BlurtDesign
import BlurtEngine
import SwiftUI

/// A key term as the design system's pill: full radius, the page's fill inside
/// the card, a hairline, the body face. Its × removes it.
struct TermPill: View {
  let term: String
  let remove: () -> Void

  var body: some View {
    HStack(spacing: DesignTokens.Metrics.appLineGap) {
      Text(term)
        .font(BlurtType.body(DesignTokens.Typography.sizeCaption))
        .foregroundStyle(BlurtBrand.text)
      Button(action: remove) {
        Image(systemName: "xmark")
          .font(.system(size: DesignTokens.Typography.sizePillGlyph, weight: .bold))
          .foregroundStyle(BlurtBrand.muted)
          .frame(width: DesignTokens.Metrics.appPillRemove, height: DesignTokens.Metrics.appPillRemove)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Remove \(term)")
    }
    .padding(.leading, DesignTokens.Metrics.appChipPadX)
    .padding(.trailing, DesignTokens.Metrics.appPillPadY)
    .padding(.vertical, DesignTokens.Metrics.appPillPadY)
    .background(BlurtBrand.page, in: Capsule())
    .overlay(Capsule().strokeBorder(BlurtBrand.cardBorder, lineWidth: DesignTokens.Metrics.cardBorder))
  }
}

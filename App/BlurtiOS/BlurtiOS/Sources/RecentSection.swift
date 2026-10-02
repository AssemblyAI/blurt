import BlurtDesign
import SwiftUI
import UIKit

/// The recent dictations as cards under their eyebrow: the words, the style
/// as a small mono tag, the time, a copy button.
struct RecentSection: View {
  var coordinator: DictationCoordinator

  var body: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Metrics.appStackGap) {
      Eyebrow("Recent")
      if coordinator.recent.displayed.isEmpty {
        Text("Your recent blurts will appear here.")
          .font(BlurtType.body(DesignTokens.Typography.sizeBody)).foregroundStyle(BlurtBrand.muted)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(DesignTokens.Metrics.appCardPad)
          .card()
      }
      ForEach(coordinator.recent.displayed) { entry in
        VStack(alignment: .leading, spacing: DesignTokens.Metrics.appLineGap) {
          Text(entry.text)
            .font(BlurtType.body(DesignTokens.Typography.sizeBody)).foregroundStyle(BlurtBrand.text)
            .lineLimit(3)  // literal-ok: three lines of a dictation
          HStack(spacing: DesignTokens.Metrics.appChipGap) {
            if let style = entry.style { Eyebrow(style, color: BlurtBrand.accent) }
            Text(entry.relativeLabel(now: Date()))
              .font(BlurtType.body(DesignTokens.Typography.sizeCaption)).foregroundStyle(BlurtBrand.muted)
            Spacer()
            Button {
              UIPasteboard.general.string = entry.text
            } label: {
              Image(systemName: "doc.on.doc")
                .font(.system(size: DesignTokens.Typography.sizeGlyph, weight: DesignTokens.Typography.weightGlyph))
                .foregroundStyle(BlurtBrand.muted)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Copy")
          }
        }
        .padding(DesignTokens.Metrics.appCardPad)
        .card()
      }
    }
  }
}

import SwiftUI
import UIKit

/// The recent dictations as cards, with a copy button each.
struct RecentSection: View {
  var coordinator: DictationCoordinator

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Recent").font(.headline)
      if coordinator.recent.displayed.isEmpty {
        Text("Your recent blurts will appear here.")
          .font(.callout).foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(16)
          .card()
      }
      ForEach(coordinator.recent.displayed) { entry in
        VStack(alignment: .leading, spacing: 8) {
          Text(entry.text).font(.body).lineLimit(3)
          HStack(spacing: 8) {
            if let style = entry.style {
              Text(style)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(BlurtBrand.accent.opacity(0.15)))
            }
            Text(entry.relativeLabel(now: Date())).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button {
              UIPasteboard.general.string = entry.text
            } label: {
              Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Copy")
          }
        }
        .padding(16)
        .card()
      }
    }
  }
}

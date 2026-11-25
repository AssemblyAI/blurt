import SwiftUI

/// An empty list's message, sized for this small panel: a glyph, a headline,
/// a callout hint — the scale of "Ready when you are", where the system's
/// `ContentUnavailableView` sets a full-window title.
struct EmptyListMessage: View {
  let title: String
  let systemImage: String
  let hint: String

  var body: some View {
    VStack(spacing: 6) {
      Image(systemName: systemImage)
        .font(.title2)
        .foregroundStyle(.tertiary)
        .accessibilityHidden(true)
      Text(title)
        .font(.headline)
      if !hint.isEmpty {
        Text(hint)
          .font(.callout)
          .foregroundStyle(.secondary)
      }
    }
    .multilineTextAlignment(.center)
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityElement(children: .combine)
  }
}

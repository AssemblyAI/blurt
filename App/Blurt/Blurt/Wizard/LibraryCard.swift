import AppKit
import SwiftUI

/// A Library card, drawn as a list row's background: white, rounded and
/// lifted, inset by the window's margin and half the gap between cards; when
/// selected, ringed in the accent, as Journal marks an entry.
struct LibraryCard: View {
  /// The space between two cards.
  static let gap: CGFloat = 4
  /// The selection ring's width, outside the card.
  static let ring: CGFloat = 3

  let isSelected: Bool

  var body: some View {
    RoundedRectangle(cornerRadius: 12, style: .continuous)
      .fill(Color(nsColor: .textBackgroundColor))
      .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
      // Selected, as Journal marks an entry: a thick accent ring just
      // outside the card, its corners following the card's.
      .background {
        if isSelected {
          RoundedRectangle(cornerRadius: 12 + Self.ring, style: .continuous)
            .fill(BlurtBrand.accent)
            .padding(-Self.ring)
        }
      }
      .padding(.horizontal, 20)
      .padding(.vertical, Self.gap)
  }
}

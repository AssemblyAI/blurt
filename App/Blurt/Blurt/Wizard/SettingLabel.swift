import SwiftUI

/// The icon-and-title label every settings row leads with — `SettingRow`'s, and
/// the label of each settings `Toggle`, so a switch row lines up with a picker
/// row above it.
struct SettingLabel: View {
  /// Wide enough for the widest row glyph (`keyboard`). A
  /// bare `Label` sizes its icon slot to each symbol's own width, so a narrow
  /// glyph (`mic`) pulled its title left of a wide one's (`keyboard`) and no two
  /// rows' titles started at the same x.
  private static let iconWidth: CGFloat = 22

  var title: String
  var systemImage: String
  var subtitle: String?

  var body: some View {
    // The glyph carries the brand green, the title stays label-colored: the
    // design tints only the icon, and a green title would read as a link.
    // Built with the closure form and the color applied to the `Image` alone,
    // rather than `.foregroundStyle(.primary, BlurtBrand.accent)` on a
    // `Label(_:systemImage:)` — a label's icon doesn't reliably draw at the
    // secondary style level, so the two-argument form leaves it label-colored.
    Label {
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
        if let subtitle {
          Text(subtitle)
            // 11 pt, System Settings' size for a row's description: a step
            // below the 13 pt title, so the two lines read as label and gloss.
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .truncationMode(.tail)
        }
      }
    } icon: {
      Image(systemName: systemImage)
        .foregroundStyle(BlurtBrand.accent)
        .frame(width: Self.iconWidth)
    }
  }
}

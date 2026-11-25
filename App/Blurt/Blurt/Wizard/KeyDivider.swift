import SwiftUI

/// The hairline between key rows: the separator colour, faint on the pale
/// panel, across the whole row — icon and all — inset as the rows are.
struct KeyDivider: View {
  var body: some View {
    Rectangle()
      .fill(Color(nsColor: .separatorColor).opacity(0.6))
      .frame(height: 0.5)
      .padding(.horizontal, 10)
      .accessibilityHidden(true)
  }
}

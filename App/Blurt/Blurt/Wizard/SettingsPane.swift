import SwiftUI

/// The chrome every settings pane shares: a grouped, non-scrolling `Form` that
/// hugs its content, so each pane sizes the window to exactly its sections and
/// the panes can't drift apart in layout.
struct SettingsPane<Content: View>: View {
  @ViewBuilder var content: Content

  var body: some View {
    Form { content }
      .formStyle(.grouped)
      .scrollDisabled(true)
      .fixedSize(horizontal: false, vertical: true)
  }
}

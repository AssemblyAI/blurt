import SwiftUI

/// The Read Aloud tab: its own pane, before Styles, rather than part of the
/// Keys tab — which keys read is a key's business, how a read sounds isn't.
struct ReadAloudSettingsTab: View {
  let coordinator: AppCoordinator

  var body: some View {
    SettingsPane {
      ReadAloudSection(coordinator: coordinator)
    }
  }
}

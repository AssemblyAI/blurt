import SwiftUI

/// The enhanced-transcripts switch and the user's style profiles — their own
/// pane rather than an Advanced section. The switch leads because styles only shape the enhanced rewrite:
/// with it off they're disabled, and the switch that re-enables them sits
/// directly above rather than on another pane.
struct StylesSettingsTab: View {
  var body: some View {
    SettingsPane {
      TranscriptionSection()
      StyleProfilesSection()
    }
  }
}

import BlurtEngine
import SwiftUI

/// The Style row's section footer, shown only while enhanced transcripts are
/// off: then every choice gives the same raw transcript, and a pop-up that
/// changes nothing needs saying so. Otherwise the footer is empty — the
/// selected style's name is the row's whole readout, its instructions live in
/// Settings.
struct StylesInertNotice: View {
  /// The same caveat inside Settings, where the Enhanced transcripts switch is
  /// on screen — the Styles pane's and the Keys tab's footer.
  static let settingsText = "Turn on Enhanced transcripts to use styles."

  /// Observed so the notice follows the toggle in the Settings window live.
  @AppStorage(EnhancedTranscriptsStore.defaultsKey)
  private var enhancedTranscripts = EnhancedTranscriptsStore.defaultValue

  var body: some View {
    if !enhancedTranscripts {
      Text("Enhanced transcripts are off in Settings, so styles don't apply.")
    }
  }
}

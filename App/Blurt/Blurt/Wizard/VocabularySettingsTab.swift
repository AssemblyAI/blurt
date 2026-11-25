import SwiftUI

/// The Vocabulary pane of the Settings window: the words Blurt should know —
/// key terms that prime transcription spelling, and text shortcuts that replace
/// a spoken phrase with saved text. Both are lists of words the user curates,
/// so they share a pane rather than key terms trailing General's pickers.
struct VocabularySettingsTab: View {
  var body: some View {
    SettingsPane {
      KeyTermsStepView()
      TextShortcutsSection()
    }
  }
}

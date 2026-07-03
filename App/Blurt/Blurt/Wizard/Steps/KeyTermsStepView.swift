import BlurtEngine
import SwiftUI

/// The "Key Terms" section of the Settings window: a free-text
/// area where the user lists comma-separated domain words (names, jargon, product
/// names). These are folded into every transcription's prompt as spelling priming
/// (see `KeyTermsStore` / `TranscriptionPrompt.build`), so the model favors those
/// spellings. Optional — it never gates setup; an empty list just sends no terms.
struct KeyTermsStepView: View {
  /// Stored in UserDefaults so multiple settings windows/readers see edits live.
  @AppStorage(KeyTermsStore.defaultsKey) private var text = ""

  var body: some View {
    Section {
      // A vertical-axis TextField gives a native placeholder (`prompt`) and grows
      // with content up to `lineLimit`, so there's no need to fake a placeholder by
      // overlaying Text on a TextEditor. `labelsHidden` keeps the title for
      // accessibility without repeating the section header inline.
      TextField(
        text: $text,
        prompt: Text("e.g. AssemblyAI, Kubernetes, Anthropic, Blurt"),
        axis: .vertical
      ) {
        Text("Key Terms")
      }
      .labelsHidden()
      .lineLimit(2...6)
      .font(.body)
      .disableAutocorrection(true)
      .accessibilityIdentifier("settings.keyTerms.field")
      .onChange(of: text) { _, newValue in KeyTermsStore.set(newValue) }
    } header: {
      Text("Key Terms")
    } footer: {
      Text("Names, jargon, and product terms to prime transcription spelling.")
    }
  }
}

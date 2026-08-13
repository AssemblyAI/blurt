import BlurtEngine
import SwiftUI

/// The "Key Terms" section of the Settings window: a free-text
/// area where the user lists comma-separated domain words (names, jargon, product
/// names). These are meant as spelling priming (see `KeyTermsStore`), so the model
/// favors those spellings. Optional — it never gates setup; an empty list just
/// sends no terms.
///
/// **They reach nothing today**: the transcription prompt's `Keywords:` clause —
/// the only thing that ever carried them — is gone, so the terms are stored and
/// read at press time and then dropped. Left in place, with the field's wiring
/// intact, because the intent is right and only the transport was wrong; if no
/// replacement lands, this section should go rather than keep promising an effect
/// it doesn't have.
struct KeyTermsStepView: View {
  /// Stored in UserDefaults so multiple settings windows/readers see edits live.
  ///
  /// `@AppStorage` is the **only** writer of this slot, which is why the store
  /// deliberately exposes no setter. Normalization happens on read instead —
  /// `KeyTermsStore.raw` trims, and `parse` trims and dedupes each term — so a
  /// blank field still reads back as "no terms". A normalizing setter fought the
  /// text field: it wrote a second, differently-normalized value on every
  /// keystroke, `@AppStorage` observed that as an external write and pushed the
  /// trimmed string back into the binding, so a trailing space was deleted as the
  /// user typed it and could never be entered at all.
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
      .accessibilityIdentifier(UITestIdentifiers.keyTermsField)
    } header: {
      Text("Key Terms")
    } footer: {
      Text("Names, jargon, and product terms to prime transcription spelling.")
    }
  }
}

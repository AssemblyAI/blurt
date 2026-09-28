import BlurtEngine
import SwiftUI

struct VibeDictateSettingsTab: View {
  @ObservedObject var history: HistoryModel
  @State private var openRouterKey = OpenRouterAPIKeyStore.current ?? ""
  @State private var vocabulary = VocabularyStore().terms.joined(separator: ", ")
  @State private var saveMessage: String?
  @AppStorage(OpenRouterModelStore.defaultsKey)
  private var modelID = OpenRouterTextNormalizer.defaultModel

  var body: some View {
    Form {
      Section("APIs") {
        SecureField("OpenRouter API key", text: $openRouterKey)
        TextField("OpenRouter model", text: $modelID)
        Button("Save API Settings") { saveAPIs() }
      }

      Section("Vocabulary") {
        TextEditor(text: $vocabulary)
          .font(.body.monospaced())
          .frame(minHeight: 90)
        Button("Save Vocabulary") { saveVocabulary() }
      }

      Section("History") {
        LabeledContent("Text retention", value: "30 days")
        LabeledContent("Audio retention", value: "3 days")
        Button("Clear History", role: .destructive) { history.clearHistory() }
      }

      Section("Privacy") {
        Text(
          "VibeDictate has no analytics or telemetry. Audio and transcripts stay local except "
            + "when they are sent to your configured AssemblyAI and OpenRouter accounts."
        )
        .foregroundStyle(.secondary)
      }

      if let saveMessage {
        Text(saveMessage).font(.caption).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .frame(minHeight: 430)
  }

  private func saveAPIs() {
    let keySaved = OpenRouterAPIKeyStore.save(openRouterKey)
    OpenRouterModelStore().save(modelID)
    modelID = OpenRouterModelStore().modelID
    saveMessage = keySaved ? "API settings saved." : "Could not save the OpenRouter key."
  }

  private func saveVocabulary() {
    let terms =
      vocabulary
      .split(whereSeparator: { $0 == "," || $0 == "\n" })
      .map(String.init)
    VocabularyStore().save(terms)
    vocabulary = VocabularyStore().terms.joined(separator: ", ")
    saveMessage = "Vocabulary saved."
  }
}

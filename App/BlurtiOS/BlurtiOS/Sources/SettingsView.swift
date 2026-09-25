import BlurtEngine
import SwiftUI

/// Everything adjustable, grouped the way the Mac's Settings are: the keyboard
/// (layout, hands-free), listening, transcription, the account, and
/// about. Presented from the home screen's gear.
struct SettingsView: View {
  var coordinator: DictationCoordinator
  @Environment(\.dismiss) private var dismiss
  @State private var layout = SharedStore.layout
  @State private var autoDictate = SharedStore.autoDictate
  @State private var windowMinutes = SharedStore.windowMinutes
  @State private var showsKeyEntry = false
  @AppStorage(KeyTermsStore.defaultsKey) private var keyTerms = ""
  @AppStorage(EnhancedTranscriptsStore.defaultsKey) private var enhancedTranscripts =
    EnhancedTranscriptsStore.defaultValue

  var body: some View {
    NavigationStack {
      Form {
        keyboardSection
        listeningSection
        transcriptionSection
        accountSection
        aboutSection
      }
      .navigationTitle("Settings")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
      }
      .sheet(isPresented: $showsKeyEntry) { KeyEntryView(apiKey: coordinator.apiKey) }
    }
    .tint(BlurtBrand.accent)
  }

  private var keyboardSection: some View {
    Section {
      Picker("Layout", selection: $layout) {
        ForEach(KeyboardLayout.allCases) { Text($0.title).tag($0) }
      }
      .pickerStyle(.segmented)
      .onChange(of: layout) { _, value in SharedStore.layout = value }
      Text(layout.summary).font(.footnote).foregroundStyle(.secondary)
      Toggle("Hands-free", isOn: $autoDictate)
        .onChange(of: autoDictate) { _, value in SharedStore.autoDictate = value }
    } header: {
      Text("Keyboard")
    } footer: {
      Text(
        "Hands-free starts dictating the moment the Blurt keyboard comes up in a text field; tap the mic to stop. "
          + "The keyboard picks up changes the next time it appears.")
    }
  }

  private var listeningSection: some View {
    Section {
      Picker("Keep listening for", selection: $windowMinutes) {
        Text("5 minutes").tag(5)
        Text("15 minutes").tag(15)
        Text("1 hour").tag(60)
        Text("Until I stop it").tag(0)
      }
      .onChange(of: windowMinutes) { _, value in SharedStore.windowMinutes = value }
    } header: {
      Text("Listening")
    } footer: {
      Text("How long the mic stays open with nobody dictating, so the keyboard can start without opening Blurt.")
    }
  }

  private var transcriptionSection: some View {
    Section {
      Toggle("Enhanced transcripts", isOn: $enhancedTranscripts)
      NavigationLink("Output styles") { StylesView() }
      TextField("Key terms, comma-separated", text: $keyTerms, axis: .vertical)
        .autocorrectionDisabled()
    } header: {
      Text("Transcription")
    } footer: {
      Text(
        "Enhanced transcripts clean up punctuation and wording. Key terms are names and jargon to spell right; "
          + "\(coordinator.lexiconNameCount) contact names come along automatically.")
    }
  }

  private var accountSection: some View {
    Section("Account") {
      LabeledContent("Sign in with AssemblyAI", value: "Coming soon")
      #if DEBUG
        Button(coordinator.apiKey.hasAPIKey ? "Replace the API key" : "Use an API key") { showsKeyEntry = true }
      #endif
    }
  }

  private var aboutSection: some View {
    Section("About") {
      LabeledContent("Version", value: Self.version)
      Link("Blurt on GitHub", destination: URL(string: "https://github.com/AssemblyAI/blurt") ?? URL(filePath: "/"))
      Text("Powered by AssemblyAI").foregroundStyle(.secondary)
    }
  }

  private static var version: String {
    let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    return "\(short) (\(build))"
  }
}

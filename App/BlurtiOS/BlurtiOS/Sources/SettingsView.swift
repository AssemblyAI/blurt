import AVFoundation
import BlurtDesign
import BlurtEngine
import BlurtiOSCore
import SwiftUI

/// Everything adjustable, grouped the way the Mac's Settings are: the keyboard
/// (hands-free, delete), listening, transcription, the account, and about — a
/// form on the brand's page, its sections under mono eyebrows. Presented from
/// either tab's gear.
struct SettingsView: View {
  var coordinator: DictationCoordinator
  @Environment(\.dismiss) private var dismiss
  @State private var autoDictate = SharedStore.autoDictate
  @State private var deleteWholeDictation = SharedStore.deleteWholeDictation
  @State private var windowMinutes = SharedStore.windowMinutes
  @State private var airPodsMic = SharedStore.airPodsMic
  @State private var showsKeyEntry = false
  @State private var confirmsStatsReset = false
  @State private var showsTypingTest = false
  @State private var showsSetupSteps = false
  @State private var microphoneGranted = AVAudioApplication.shared.recordPermission == .granted
  @State private var keyboardSeen = SharedStore.keyboardEverSeen
  @Environment(\.scenePhase) private var scenePhase
  @AppStorage(TypingSpeed.defaultsKey) private var typingSpeed: Double = 0
  @AppStorage(EnhancedTranscriptsStore.defaultsKey) private var enhancedTranscripts =
    EnhancedTranscriptsStore.defaultValue

  var body: some View {
    NavigationStack {
      Form {
        setupSection
        keyboardSection
        listeningSection
        transcriptionSection
        accountSection
        dataSection
        aboutSection
      }
      .brandForm()
      .navigationTitle("Settings")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
      }
      .sheet(isPresented: $showsKeyEntry) { KeyEntryView(apiKey: coordinator.apiKey) }
      // On the form, not on a section: a section's modifiers apply to each of
      // its rows, so a cover there was presented once per row at the same time.
      .fullScreenCover(isPresented: $showsTypingTest) { TypingTestView() }
      .onChange(of: scenePhase) { _, phase in
        if phase == .active { refreshSetup() }
      }
      .confirmationDialog("Reset statistics?", isPresented: $confirmsStatsReset, titleVisibility: .visible) {
        Button("Reset", role: .destructive) { DictationStats.reset() }
      } message: {
        Text("Your dictation, word and time-saved totals go back to zero.")
      }
    }
    .tint(BlurtBrand.accent)
  }

  /// The first-run steps, kept here once the app is set up: folded to a line
  /// while everything is done, open while
  /// something (the microphone, the keyboard) is still missing.
  private var setupSection: some View {
    let isSetUp = coordinator.apiKey.hasAPIKey && microphoneGranted && keyboardSeen
    return Section {
      if isSetUp {
        HStack {
          Text("Blurt is set up")
          Image(systemName: "checkmark").foregroundStyle(BlurtBrand.accent)
          Spacer()
          Button(showsSetupSteps ? "Hide steps" : "Show steps") { showsSetupSteps.toggle() }
            .font(BlurtType.body(DesignTokens.Typography.sizeCaption, bold: true))
            .foregroundStyle(BlurtBrand.accent)
            .buttonStyle(.plain)
        }
      }
      if !isSetUp || showsSetupSteps {
        SetupSteps(
          hasKey: coordinator.apiKey.hasAPIKey, microphoneGranted: microphoneGranted, keyboardSeen: keyboardSeen,
          refresh: refreshSetup
        ) {
          Button("Add an API key") { showsKeyEntry = true }.buttonStyle(BrandButtonStyle())
        }
        .padding(.vertical, DesignTokens.Metrics.appRowPadY)
      }
    } header: {
      Eyebrow("Setup")
    }
  }

  private func refreshSetup() {
    microphoneGranted = AVAudioApplication.shared.recordPermission == .granted
    keyboardSeen = SharedStore.keyboardEverSeen
    coordinator.apiKey.refreshStatus()
  }

  /// The keyboard is Apple's, so there is nothing of its look to choose; the
  /// one thing to set is whether it starts dictating on its own.
  private var keyboardSection: some View {
    Section {
      Toggle("Hands-free", isOn: $autoDictate)
        .onChange(of: autoDictate) { _, value in SharedStore.autoDictate = value }
      Toggle("Delete whole dictation", isOn: $deleteWholeDictation)
        .onChange(of: deleteWholeDictation) { _, value in SharedStore.deleteWholeDictation = value }
    } header: {
      Eyebrow("Keyboard")
    } footer: {
      Text(
        "Hands-free starts dictating the moment the Blurt keyboard comes up in a text field; tap the mic to stop. "
          + "Delete whole dictation makes delete right after a dictation take all of it back; "
          + "off, delete removes one character. "
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
      .onChange(of: windowMinutes) { _, value in
        SharedStore.windowMinutes = value
        // The window that is open takes the new length, not only the next one.
        coordinator.windowMinutesChanged()
      }
      Toggle("Use AirPods mic", isOn: $airPodsMic)
        .onChange(of: airPodsMic) { _, value in SharedStore.airPodsMic = value }
    } header: {
      Eyebrow("Listening")
    } footer: {
      Text(
        "How long a session stays on with nobody dictating, counted from the last word, so the keyboard can start "
          + "without opening Blurt. With AirPods, the phone's own mic is used and music stays stereo; "
          + "Use AirPods mic takes theirs instead, from the next session.")
    }
  }

  private var transcriptionSection: some View {
    Section {
      Toggle("Enhanced transcripts", isOn: $enhancedTranscripts)
      NavigationLink("Output styles") { StylesView() }
    } header: {
      Eyebrow("Transcription")
    } footer: {
      Text("Enhanced transcripts clean up punctuation and wording.")
    }
  }

  private var accountSection: some View {
    Section {
      Button(coordinator.apiKey.hasAPIKey ? "Replace the API key" : "Add an API key") { showsKeyEntry = true }
      Link("Get a free key", destination: APIKeyStore.dashboardURL)
    } header: {
      Eyebrow("Account")
    }
  }

  /// The stats card's totals, which live only on this phone.
  private var dataSection: some View {
    Section {
      Button("Reset statistics", role: .destructive) { confirmsStatsReset = true }
    } header: {
      Eyebrow("Data")
    } footer: {
      Text("Dictations, words and time saved are counted on this phone and never sent.")
    }
  }

  private var aboutSection: some View {
    Section {
      LabeledContent("Version", value: Self.version)
      Link("Blurt on GitHub", destination: URL(string: "https://github.com/AssemblyAI/blurt") ?? URL(filePath: "/"))
      Link("AssemblyAI's privacy policy", destination: AIConsent.privacyPolicyURL)
      Text("Powered by AssemblyAI").foregroundStyle(BlurtBrand.muted)
      // The easter egg: a link, not a button, so it stays a find rather than
      // another call to action. Its result becomes time saved's typing speed.
      Button {
        showsTypingTest = true
      } label: {
        Label("How fast can you type?", systemImage: "keyboard")
      }
      .foregroundStyle(BlurtBrand.accent)
      if typingSpeed > 0 {
        Button("Using your \(Int(typingSpeed)) wpm · Reset to average") { TypingSpeed.resetToAverage() }
          .font(BlurtType.body(DesignTokens.Typography.sizeCaption))
          .foregroundStyle(BlurtBrand.muted)
      }
    } header: {
      Eyebrow("About")
    }
  }

  private static var version: String {
    let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    return "\(short) (\(build))"
  }
}

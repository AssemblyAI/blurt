import AVFoundation
import BlurtEngine
import SwiftUI
import UIKit

/// The app's one screen: setup while anything is missing, then the listening
/// window, a way to try a dictation right here, the keyboard choice, and the
/// settings the request reads. Plain SwiftUI on purpose — the design pass comes
/// once the loop works on a phone.
struct HomeView: View {
  var coordinator: DictationCoordinator
  @Environment(\.scenePhase) private var scenePhase
  @State private var microphoneGranted = AVAudioApplication.shared.recordPermission == .granted
  @State private var keyboardSeen = SharedStore.keyboardEverSeen
  @State private var layout = SharedStore.layout
  @State private var windowMinutes = SharedStore.windowMinutes
  @State private var showsKeyEntry = false
  @AppStorage(KeyTermsStore.defaultsKey) private var keyTerms = ""
  @AppStorage(EnhancedTranscriptsStore.defaultsKey) private var enhancedTranscripts =
    EnhancedTranscriptsStore.defaultValue

  private var isSetUp: Bool { coordinator.apiKey.hasAPIKey && microphoneGranted && keyboardSeen }

  var body: some View {
    NavigationStack {
      List {
        if !isSetUp { setupSection }
        listeningSection
        tryItSection
        keyboardSection
        settingsSection
        recentSection
      }
      .navigationTitle("Blurt")
      .onChange(of: scenePhase) { _, phase in
        if phase == .active { refreshStatus() }
      }
      .sheet(isPresented: $showsKeyEntry) { KeyEntryView(apiKey: coordinator.apiKey) }
    }
    .tint(BlurtBrand.green)
  }

  private func refreshStatus() {
    microphoneGranted = AVAudioApplication.shared.recordPermission == .granted
    keyboardSeen = SharedStore.keyboardEverSeen
    coordinator.apiKey.refreshStatus()
  }

  // MARK: - Setup

  private var setupSection: some View {
    Section("Set up") {
      SetupRow(done: coordinator.apiKey.hasAPIKey, title: "Sign in with AssemblyAI") {
        VStack(alignment: .leading, spacing: 6) {
          Text("Coming soon — sign-in needs the AssemblyAI login service.")
            .font(.footnote).foregroundStyle(.secondary)
          #if DEBUG
            Button("Use an API key instead") { showsKeyEntry = true }
          #endif
        }
      }
      SetupRow(done: microphoneGranted, title: "Allow the microphone") {
        Button("Allow") {
          Task {
            await coordinator.startListening()
            refreshStatus()
          }
        }
      }
      SetupRow(done: keyboardSeen, title: "Add the Blurt keyboard") {
        VStack(alignment: .leading, spacing: 6) {
          Text(
            "Settings → Keyboards: turn on Blurt and Allow Full Access. "
              + "Full Access is what lets the keyboard send your words to Blurt."
          )
          .font(.footnote).foregroundStyle(.secondary)
          Button("Open Settings") { openAppSettings() }
        }
      }
    }
  }

  private func openAppSettings() {
    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
    UIApplication.shared.open(url)
  }

  // MARK: - Listening

  private var listeningSection: some View {
    Section("Listening") {
      if coordinator.window.isOpen {
        VStack(alignment: .leading, spacing: 6) {
          Label(listeningLabel, systemImage: "mic.fill").foregroundStyle(BlurtBrand.green)
          Text("Go back to the app you're typing in and tap the mic on the Blurt keyboard.")
            .font(.footnote).foregroundStyle(.secondary)
        }
        Button("Stop listening", role: .destructive) { coordinator.stopListening() }
      } else {
        Button("Start listening") { Task { await coordinator.startListening() } }
          .disabled(!coordinator.apiKey.hasAPIKey)
        Text("Opens the mic for \(windowLabel) so the keyboard can dictate without opening Blurt each time.")
          .font(.footnote).foregroundStyle(.secondary)
      }
      if let error = coordinator.window.lastError {
        Text(error).font(.footnote).foregroundStyle(BlurtBrand.errorOrange)
      }
      if coordinator.microphoneDenied {
        Text("Blurt needs the microphone. Allow it in Settings.").font(.footnote)
          .foregroundStyle(BlurtBrand.errorOrange)
      }
    }
  }

  private var listeningLabel: String {
    guard let until = coordinator.window.until, until != .distantFuture else { return "Listening" }
    return "Listening until \(until.formatted(date: .omitted, time: .shortened))"
  }

  private var windowLabel: String {
    windowMinutes == 0 ? "as long as you like" : "\(windowMinutes) minutes at a time"
  }

  // MARK: - Try it

  private var tryItSection: some View {
    Section("Try it here") {
      Button(coordinator.phase.isCapturing ? "Stop and transcribe" : "Dictate to the clipboard") {
        coordinator.toggleDictation()
      }
      .disabled(!coordinator.window.isOpen)
      PhaseLine(phase: coordinator.phase, level: coordinator.level)
    }
  }

  // MARK: - Keyboard

  private var keyboardSection: some View {
    Section {
      Picker("Layout", selection: $layout) {
        ForEach(KeyboardLayout.allCases) { Text($0.title).tag($0) }
      }
      .pickerStyle(.segmented)
      .onChange(of: layout) { _, value in SharedStore.layout = value }
      Text(layout.summary).font(.footnote).foregroundStyle(.secondary)
    } header: {
      Text("Keyboard")
    } footer: {
      Text("Any of the three works the same underneath; pick the one that fits how you type.")
    }
  }

  // MARK: - Settings

  private var settingsSection: some View {
    Section("Dictation") {
      Picker("Keep listening for", selection: $windowMinutes) {
        Text("5 minutes").tag(5)
        Text("15 minutes").tag(15)
        Text("1 hour").tag(60)
        Text("Until I stop it").tag(0)
      }
      .onChange(of: windowMinutes) { _, value in SharedStore.windowMinutes = value }
      Toggle("Enhanced transcripts", isOn: $enhancedTranscripts)
      NavigationLink("Output styles") { StylesView() }
      TextField("Key terms, comma-separated", text: $keyTerms, axis: .vertical)
        .autocorrectionDisabled()
      Text(
        "Names and jargon to spell right. \(coordinator.lexiconNameCount) contact names come along automatically."
      )
      .font(.footnote).foregroundStyle(.secondary)
    }
  }

  // MARK: - Recent

  private var recentSection: some View {
    Section("Recent") {
      if coordinator.recent.entries.isEmpty {
        Text("Your recent blurts will appear here").foregroundStyle(.secondary)
      }
      ForEach(coordinator.recent.displayed) { entry in
        VStack(alignment: .leading, spacing: 4) {
          Text(entry.text).lineLimit(3)
          Text(entry.relativeLabel(now: Date())).font(.caption).foregroundStyle(.secondary)
        }
        .contextMenu {
          Button("Copy") { UIPasteboard.general.string = entry.text }
        }
      }
    }
  }
}

/// One line of the setup checklist: a check or a circle, the step, and its
/// control while it is still to do.
private struct SetupRow<Action: View>: View {
  let done: Bool
  let title: String
  @ViewBuilder let action: () -> Action

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: done ? "checkmark.circle.fill" : "circle")
        .foregroundStyle(done ? BlurtBrand.green : Color.secondary)
      VStack(alignment: .leading, spacing: 6) {
        Text(title)
        if !done { action() }
      }
    }
  }
}

/// The pipeline phase as one line, with a small level meter while recording.
private struct PhaseLine: View {
  let phase: PipelinePhase
  let level: Float

  var body: some View {
    HStack(spacing: 10) {
      Text(phase.overlayState.accessibilityLabel).font(.footnote).foregroundStyle(.secondary)
      if phase == .recording {
        ProgressView(value: Double(level)).tint(BlurtBrand.green).frame(width: 80)
      }
    }
  }
}

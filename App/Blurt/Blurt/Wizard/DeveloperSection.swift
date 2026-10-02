import AppKit
import BlurtEngine
import OSLog
import SwiftUI

// The Advanced pane's four sections: updates (version, check, Sparkle's two
// preferences), experimental features, developer mode, and the start-over button. All are
// Settings-only (none gates setup, so none is a wizard step), and they live here
// rather than in `SettingsWindowRoot` because that file is at the repo's
// file-length limit.

/// The running version, a "Check for Updates…" button, and Sparkle's two
/// preferences. Every control drives the one `UpdaterModel` owned by
/// `AppDelegate` — the same updater the app-menu command and the menu-bar item
/// use — and Sparkle presents the check's progress and result itself.
///
/// In a debug build the updater never starts (see `UpdaterModel`), so the
/// controls are disabled and the footer says why rather than leaving a button
/// that silently does nothing.
struct UpdatesSection: View {
  @Bindable var model: UpdaterModel

  var body: some View {
    Section {
      // Ellipsis: it opens Sparkle's window, where an update still waits on the
      // user's go-ahead — the same rule as "Reset…" below.
      SettingRow(title: model.versionLabel, systemImage: "info.circle") {
        Button("Check for Updates…") { model.checkForUpdates() }
          .disabled(!model.canCheckForUpdates)
          .accessibilityIdentifier(UITestIdentifiers.updateCheck)
      }
      Toggle(isOn: $model.automaticallyChecksForUpdates) {
        SettingLabel(title: "Check for updates automatically", systemImage: "clock")
      }
      .disabled(!model.isEnabled)
      .accessibilityIdentifier(UITestIdentifiers.updateAutoCheck)
      // Installing on its own only means anything while Blurt is looking on its
      // own, so the second switch follows the first.
      Toggle(isOn: $model.automaticallyDownloadsUpdates) {
        SettingLabel(title: "Download and install updates automatically", systemImage: "arrow.down.circle")
      }
      .disabled(!model.isEnabled || !model.automaticallyChecksForUpdates)
    } header: {
      Text("Updates")
    } footer: {
      if !model.isEnabled {
        Text("This development build doesn’t update itself.")
      }
    }
  }
}

/// The Advanced pane's experimental features — today just read-aloud (see
/// `SelectionSpeechStore`), asking about the selection (`SelectionAskStore`)
/// and its work mode (`ReadAloudWorkModeStore`). The router reads the same
/// defaults these controls write at every press, so a change applies to the
/// next one.
struct ExperimentalSection: View {
  @AppStorage(SelectionSpeechStore.defaultsKey) private var selectionSpeech = false
  @AppStorage(SelectionAskStore.defaultsKey) private var selectionAsk = SelectionAskStore.defaultValue
  @AppStorage(ReadAloudWorkModeStore.defaultsKey) private var workMode = false
  @AppStorage(ReadAloudWorkModeStore.speedDefaultsKey) private var speed = ReadAloudWorkModeStore.defaultSpeed
  @AppStorage(ReadAloudWorkModeStore.skipsJargonDefaultsKey)
  private var skipsJargon = ReadAloudWorkModeStore.defaultSkipsJargon
  @BoundTriggerKey private var triggerKey
  @AppStorage(TriggerActivationStore.defaultsKey) private var activationRaw = ""

  /// Read-aloud rides the trigger's own tap/hold gate, so its instructions
  /// follow the activation mode. With asking on, a hold asks instead of reading,
  /// so reading is a tap's job, or, where every press is a hold, a hold with
  /// nothing said.
  private var howToUse: String {
    let activation = TriggerActivation.fromPersisted(activationRaw)
    let key = triggerKey.label
    guard selectionAsk else {
      return "Select text and \(activation.startVerb) \(key) to hear it. \(activation.stopHint)"
    }
    switch activation {
    case .hold: return "Select text and hold \(key) without speaking to hear it. Press again to stop."
    case .tapOrHold, .tap: return "Select text and tap \(key) to hear it. Tap again to stop."
    }
  }

  /// The picker reads the stored speed through the same snap the press does, so
  /// a `defaults write` value off the list shows as the speed that will play.
  private var speedSelection: Binding<Double> {
    Binding(get: { ReadAloudWorkModeStore.nearestChoice(to: speed) }, set: { speed = $0 })
  }

  var body: some View {
    Section {
      Toggle(isOn: $selectionSpeech) {
        SettingLabel(title: "Read selected text aloud", systemImage: "speaker.wave.2")
      }
      .accessibilityIdentifier(UITestIdentifiers.selectionSpeechToggle)
      // Work mode only changes how a read sounds, so its rows only appear
      // while there are reads to change.
      if selectionSpeech {
        Toggle(isOn: $selectionAsk) {
          SettingLabel(title: "Hold to ask about the selection", systemImage: "questionmark.bubble")
        }
        .accessibilityIdentifier(UITestIdentifiers.selectionAskToggle)
        Toggle(isOn: $workMode) {
          SettingLabel(title: "Work mode", systemImage: "briefcase")
        }
        .accessibilityIdentifier(UITestIdentifiers.readAloudWorkModeToggle)
        if workMode {
          PickerSettingRow(
            title: "Speed", systemImage: "hare",
            accessibilityID: UITestIdentifiers.readAloudSpeedPicker, selection: speedSelection
          ) {
            ForEach(ReadAloudWorkModeStore.speedChoices, id: \.self) { choice in
              Text(ReadAloudWorkModeStore.speedLabel(choice)).tag(choice)
            }
          }
          Toggle(isOn: $skipsJargon) {
            SettingLabel(title: "Skip code, links, and long numbers", systemImage: "text.badge.minus")
          }
          .accessibilityIdentifier(UITestIdentifiers.readAloudSkipsJargonToggle)
        }
      }
    } header: {
      Text("Experimental")
    } footer: {
      Text("\(howToUse) With nothing selected, the key dictates as usual.")
      // Each note is its own paragraph. Asking says where the selection and the
      // request go, since that is a second service seeing both.
      if selectionSpeech, selectionAsk {
        Text(
          "Hold \(triggerKey.label) over a selection and say what you want, like “summarize this,” to hear "
            + "the answer. Asking sends the selection and what you said to AssemblyAI’s LLM Gateway.")
      }
      // Work mode's: what the unexplained switch does while it's off, and, while
      // skipping is on, that the selection goes to the gateway before it's read.
      if selectionSpeech {
        if !workMode {
          Text("Work mode reads faster and can skip code, links, and long numbers.")
        } else if skipsJargon {
          Text("To leave those out, Blurt sends the selection to AssemblyAI’s LLM Gateway before reading it.")
        }
      }
    }
  }
}

/// The Advanced pane's developer-mode switch.
///
/// Developer mode is an opt-in: while on, every completed dictation is appended
/// to the local JSONL log and every failed one to a sibling error log (see
/// `DictationLog` — both gates read the same default this toggle writes), and
/// the section grows a "Show Logs in Finder" row and a footer naming where the
/// logs live.
struct MaintenanceSection: View {
  @AppStorage(DeveloperModeStore.defaultsKey) private var developerMode = false

  var body: some View {
    Section {
      Toggle(isOn: $developerMode) {
        SettingLabel(title: "Developer mode", systemImage: "hammer")
      }
      .accessibilityIdentifier(UITestIdentifiers.developerToggle)
      if developerMode {
        SettingRow(title: "Logs", systemImage: "doc.text.magnifyingglass") {
          Button("Show in Finder", action: showLogs)
            .accessibilityIdentifier(UITestIdentifiers.developerShowLogs)
        }
      }
    } footer: {
      if developerMode {
        // Both home-abbreviated paths are derived in the engine next to the URLs
        // the writers append to, so this label can never drift from where the
        // logs actually land. No trailing period: a path ends the line, so it
        // can be selected and copied without picking up punctuation — which is
        // also why the first path is followed by a plain space, not a comma.
        Text(
          "Logs each dictation to \(DictationLog.defaultDisplayPath) "
            + "and each failure to \(DictationLog.defaultErrorDisplayPath)"
        )
        .textSelection(.enabled)
      } else {
        Text("Developer mode keeps a local log of each dictation and failure.")
      }
    }
  }

  /// Opens the log directory in Finder. The directory only exists once the first
  /// entry lands, and a button that silently did nothing right after the switch
  /// went on would read as broken — so it's created here if need be (the reset
  /// sweep removes it again once it's empty).
  private func showLogs() {
    let directory = DictationLog.defaultURL.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    NSWorkspace.shared.open(directory)
  }
}

/// The Reset section of the Settings window: one destructive button that hands
/// the install back to the state a fresh download starts from — no API key, no
/// settings, no dictation logs, and none of the TCC grants — for the user whose
/// permissions have got into a state no toggle in System Settings will fix. The
/// sweep itself is the engine's `InstallReset`, the same set of steps
/// `scripts/reset-install.sh` performs, so someone who can't (or shouldn't have
/// to) run a shell script has the same way out.
///
/// **Blurt restarts itself when it finishes**, which the confirmation says up
/// front. That isn't politeness: the running process is the one holding the TCC
/// grants the sweep just revoked, and macOS re-prompts per process — so only a
/// process started *after* the reset gets the permission prompts back. The new
/// one comes up with no key and no grants, which is exactly the state
/// `SetupReadiness` reads as "not configured", so it opens on the setup wizard
/// (`MainWindowRoot`) rather than the ready screen. Restarting rather than
/// merely quitting is what makes the button finish the job the user asked for
/// instead of leaving them at a closed app.
struct ResetSection: View {
  /// What the section is asking or telling, or nil while it's silent.
  ///
  /// **One piece of state and one `.alert` modifier**, because two `.alert`s on
  /// the same view is the classic SwiftUI conflict where only one of them ever
  /// presents — with the report attached second, the confirmation never opened
  /// at all, which is how `SettingsUITests` caught it.
  private enum Prompt {
    /// Asked before anything happens. A reset is irreversible and machine-wide,
    /// so the button opens this rather than acting on the click.
    case confirm
    /// Only shown when part of the sweep survived. A clean reset says nothing:
    /// the app restarting into setup is the confirmation.
    case failed(InstallReset.AlertContent)

    var title: String {
      switch self {
      case .confirm: "Reset Blurt?"
      case .failed(let content): content.title
      }
    }

    var message: String {
      switch self {
      case .confirm:
        "This can’t be undone. Your AssemblyAI API key, every setting, the dictation logs, and "
          + "Blurt’s microphone and accessibility permissions will all be removed.\n\n"
          + "Blurt then restarts and takes you back through setup."
      case .failed(let content): content.message
      }
    }
  }

  let coordinator: AppCoordinator

  @State private var prompt: Prompt?

  var body: some View {
    // No header: "Reset" over a "Reset Blurt" row only said the same word
    // twice, and the red button and the footer already say what this is.
    Section {
      // Ellipsis for the same reason as "Connect…" and "Add Style…": the button
      // opens something rather than completing the action.
      SettingRow(title: "Reset Blurt", systemImage: "arrow.counterclockwise") {
        // Red text, because `role: .destructive` alone draws a bordered
        // button no differently from "Check for Updates…" in the sections
        // above — and this one deletes the key, every setting and the logs.
        Button(role: .destructive) {
          prompt = .confirm
        } label: {
          Text("Reset…").foregroundStyle(.red)
        }
        .accessibilityIdentifier(UITestIdentifiers.installReset)
      }
    } footer: {
      // The sweep still clears Input Monitoring (`PermissionsReset.sweep`), so
      // a grant left by a build from before the hotkey stopped needing it goes
      // too — but no current install has one, so naming it here only told
      // users about a permission they were never asked for.
      Text(
        "Deletes your AssemblyAI API key, clears every setting, removes the dictation logs, and "
          + "revokes Blurt’s microphone and accessibility permissions.")
    }
    // Alert buttons are addressed by the words on them in the UI suite, like the
    // update alert's "OK" — an identifier here wouldn't survive AppKit's alert
    // bridging. Cancel stays the default action; the destructive one never takes
    // Return.
    .alert(prompt?.title ?? "", isPresented: isPrompting, presenting: prompt) { prompt in
      switch prompt {
      case .confirm:
        // Deferred a turn: setting `prompt` straight from an alert action
        // re-enters presentation while this alert is still dismissing, and
        // SwiftUI swallows it — so the failure report would never appear.
        Button("Reset and Restart", role: .destructive) { Task { @MainActor in reset() } }
        Button("Cancel", role: .cancel) {}
      case .failed:
        Button("OK", role: .cancel) {}
      }
    } message: { prompt in
      Text(prompt.message)
    }
  }

  /// Presentation binding derived from `prompt`, so there's one piece of state
  /// rather than a bool that can disagree with it.
  private var isPrompting: Binding<Bool> {
    Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } })
  }

  /// Runs the sweep, then restarts — or reports what survived and stays put.
  ///
  /// The bundle id is the **running** one, never `HostIdentity.current.subsystem`:
  /// debug builds ship under `dev.alex.blurt.dev`, and the constant would have a
  /// dev build clearing the released Blurt's grants (the same rule
  /// `AppDelegate.runAccessibilityGrantMigration` follows). The key is cleared
  /// through the model's own storage seam, so a UI-test run sweeps its in-memory
  /// store instead of the developer's Keychain item.
  private func reset() {
    let report = InstallReset(
      bundleID: Bundle.main.bundleIdentifier ?? HostIdentity.current.subsystem,
      keyStore: coordinator.apiKey.storage
    ).run()
    // `hasAPIKey` is a mirror of the store, not a read-through, so it has to be
    // re-read for the wizard to see the key go — which matters on the failure
    // path, where the app stays running.
    coordinator.apiKey.refreshStatus()
    // Nothing to report means the install is clean, and the fresh copy opening
    // on the setup wizard is the whole confirmation — a success alert would only
    // be one more click between the user and the setup they came for.
    guard let report else {
      restart()
      return
    }
    prompt = .failed(report)
  }

  /// Replaces this process with a fresh one, so the permission prompts come back
  /// (macOS asks once per process, and this one has already been asked).
  ///
  /// A detached `sh` does the launching because *we* can't: whatever reopens
  /// Blurt has to outlive Blurt. It sleeps first so `open` runs against a bundle
  /// with no live instance, and takes `-n` so that if the old process is somehow
  /// still shutting down, LaunchServices starts a new copy rather than
  /// re-activating the dying one and leaving the user with nothing. The overlap
  /// that `-n` risks is harmless here: a just-reset copy has no key and no
  /// grants, so it installs no event tap and shows no pill — it opens the wizard
  /// and waits.
  ///
  /// The bundle path is passed as an argument rather than interpolated into the
  /// script, so a path with spaces (`/Applications/Blurt Dev.app`) can't split
  /// into two words.
  ///
  /// A failed launch is not worth an alert: the sweep itself already succeeded,
  /// and the recovery — open Blurt again — is the thing the user was about to do
  /// anyway.
  private func restart() {
    let relauncher = Process()
    relauncher.executableURL = URL(fileURLWithPath: "/bin/sh")
    relauncher.arguments = ["-c", "sleep 1; /usr/bin/open -n \"$0\"", Bundle.main.bundlePath]
    do {
      try relauncher.run()
    } catch {
      HostIdentity.current.logger("reset").error(
        "relaunch after reset failed to spawn: \(error.localizedDescription, privacy: .public)")
    }
    NSApp.terminate(nil)
  }
}

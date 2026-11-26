import AppKit
import BlurtAssemblyAI
import BlurtEngine
import OSLog
import SwiftUI

/// The Reset section of the Settings window: one destructive button that hands
/// the install back to the state a fresh download starts from — no API key, no
/// settings, no dictation logs, and none of the TCC grants — for the user whose
/// permissions have got into a state no toggle in System Settings will fix. The
/// sweep itself is the engine's `InstallReset`, the same set of steps
/// `scripts/reset-install.sh` (or `reset-dev-install.sh`) performs, so someone who can't (or shouldn't have
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
      case .confirm:
        "Reset Blurt?"

      case .failed(let content):
        content.title
      }
    }

    var message: String {
      switch self {
      case .confirm:
        "This can’t be undone. Your AssemblyAI API key, every setting, the dictation logs, and "
          + "Blurt’s microphone and accessibility permissions will all be removed.\n\n"
          + "Blurt then restarts and takes you back through setup."

      case .failed(let content):
        content.message
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
      SettingRow(
        title: "Reset Blurt",
        systemImage: "arrow.counterclockwise",
        subtitle: "Remove app data and return to setup."
      ) {
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
          + "revokes Blurt’s microphone and accessibility permissions."
      )
    }
    // Alert buttons are addressed by the words on them in the UI suite, like the
    // update alert's "OK" — an identifier here wouldn't survive AppKit's alert
    // bridging. Cancel stays the default action; the destructive one never takes
    // Return.
    .alert(prompt?.title ?? "", isPresented: $prompt.isPresent(), presenting: prompt) { prompt in
      switch prompt {
      case .confirm:
        // Deferred a turn: setting `prompt` straight from an alert action
        // re-enters presentation while this alert is still dismissing, and
        // SwiftUI swallows it — so the failure report would never appear.
        Button("Reset and Restart", role: .destructive) { Task { reset() } }
        Button("Cancel", role: .cancel) {
          // Dismissing is the whole action: the system closes the alert.
        }

      case .failed:
        Button("OK", role: .cancel) {
          // Dismissing is the whole action: the system closes the alert.
        }
      }
    } message: { prompt in
      Text(prompt.message)
    }
  }

  /// Runs the sweep, then restarts — or reports what survived and stays put.
  ///
  /// The bundle id is the **running** one (`HostIdentity.runningBundleID`), so
  /// a dev build never clears the released Blurt's grants. The key is cleared
  /// through the model's own storage seam, so a UI-test run sweeps its in-memory
  /// store instead of the developer's Keychain item.
  private func reset() {
    let report = InstallReset(
      bundleID: HostIdentity.current.runningBundleID,
      keyStore: coordinator.apiKey.storage
    ) { [storage = coordinator.account.storage] in
      storage.save(nil)
    }
    .run()
    coordinator.account.refreshStatus()
    // `hasAPIKey` is a mirror of the store, not a read-through, so it has to be
    // re-read for the wizard to see the key go — which matters on the failure
    // path, where the app stays running. The account's refresh above re-reads
    // the key too, but not when the session item can't be read, so this one
    // isn't redundant.
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
        "relaunch after reset failed to spawn: \(error.localizedDescription, privacy: .public)"
      )
    }
    NSApp.terminate(nil)
  }
}

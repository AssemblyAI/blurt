import AppKit
import BlurtEngine
import OSLog
import SwiftUI

/// Features on trial, each behind its own switch, off by default. Always shown,
/// and independent of developer mode: trying one shouldn't mean logging every
/// dictation to disk.
struct ExperimentalSection: View {
  @AppStorage(MediaPauseStore.defaultsKey)
  private var pauseMedia = false
  @AppStorage(EscapeCancelStore.defaultsKey)
  private var escapeCancels = false
  /// Each player's Automation consent, read whenever the section appears, the
  /// app comes back to the front (from System Settings, say), or the switch
  /// turns on — so the note is right after a relaunch too.
  @State private var consent: [MediaPlayerApp: AutomationConsent] = [:]
  /// The consent read in flight. Each read cancels the one before, so only the
  /// newest answer lands: one answered after the switch went off can't bring
  /// back a note.
  @State private var consentRead: Task<Void, Never>?

  var body: some View {
    Section {
      Toggle(isOn: $pauseMedia) {
        SettingLabel(
          title: "Pause music while dictating",
          systemImage: "pause.circle",
          subtitle: "Pauses Spotify or Music while you speak, and resumes it when you stop."
        )
      }
      .accessibilityIdentifier(UITestIdentifiers.pauseMediaToggle)
      // Ask for Automation consent now, not mid-dictation.
      .onChange(of: pauseMedia) { _, isOn in readConsent(prompting: isOn) }
      Toggle(isOn: $escapeCancels) {
        SettingLabel(
          title: "Cancel with Escape",
          systemImage: "escape",
          subtitle: "Esc discards a dictation, request or answer in progress, from any app."
        )
      }
      .accessibilityIdentifier(UITestIdentifiers.escapeCancelToggle)
    } header: {
      Text("Experimental")
    } footer: {
      // Only the consent notes: the panes don't scroll, and each row's subtitle
      // says what it does.
      if pauseMedia { consentNotes }
    }
    .task { readConsent(prompting: false) }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      readConsent(prompting: false)
    }
  }

  @ViewBuilder private var consentNotes: some View {
    let denied = players(.denied)
    let notAsked = players(.notAsked)
    if !denied.isEmpty {
      Text(
        "Blurt can't control \(denied). Allow it in System Settings › Privacy & Security › Automation."
      )
    }
    if !notAsked.isEmpty {
      // A player opened after the switch went on: a dictation won't ask, so ask here.
      HStack {
        Text("Blurt needs your permission to control \(notAsked).")
        Button("Allow…") { readConsent(prompting: true) }
      }
    }
  }

  /// The players with `state`, named for a sentence: "Spotify or Music".
  private func players(_ state: AutomationConsent) -> String {
    MediaPlayerApp.allCases.filter { consent[$0] == state }.map(\.rawValue).formatted(.list(type: .or))
  }

  private func readConsent(prompting: Bool) {
    consentRead?.cancel()
    // Off, or about to prompt: drop the old notes now, so one from before
    // doesn't sit under a switch that's off or beside the prompt it asks for.
    if !pauseMedia || prompting { consent = [:] }
    guard pauseMedia else {
      return
    }
    consentRead = Task {
      let answer = await MediaPauseController.consent(prompting: prompting)
      guard !Task.isCancelled else {
        return
      }
      consent = answer
    }
  }
}

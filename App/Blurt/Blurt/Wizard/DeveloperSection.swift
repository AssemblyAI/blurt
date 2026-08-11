import BlurtEngine
import SwiftUI

/// The Developer section of the Settings window: an opt-in switch for developer
/// mode. While on, every completed dictation is appended to the local JSONL log
/// (see `DictationLog` — its gate reads the same default this toggle writes),
/// and the footer shows where that log lives so it's easy to find. Settings-only
/// — not a wizard step, since it never gates setup.
struct DeveloperSection: View {
  @AppStorage(DeveloperModeStore.defaultsKey) private var developerMode = false

  var body: some View {
    Section {
      Toggle(isOn: $developerMode) {
        Label("Developer mode", systemImage: "hammer")
      }
      .accessibilityIdentifier(UITestIdentifiers.developerToggle)
    } header: {
      Text("Developer")
    } footer: {
      // The home-abbreviated path is derived in the engine next to the URL the
      // writer appends to, so this label can never drift from where the log
      // actually lands. No trailing period: the path ends the line so it can be
      // selected and copied without picking up punctuation.
      Text("Logs each dictation to \(DictationLog.defaultDisplayPath)")
        .textSelection(.enabled)
    }
  }
}

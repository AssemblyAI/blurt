import BlurtEngine
import SwiftUI

/// The Developer section of the Settings window: an opt-in switch for developer
/// mode. While on, every completed dictation is appended to the local JSONL log
/// and every failed one to a sibling error log (see `DictationLog` — both gates
/// read the same default this toggle writes), and the footer shows where those
/// logs live so they're easy to find. Settings-only — not a wizard step, since it
/// never gates setup.
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
      // Both home-abbreviated paths are derived in the engine next to the URLs
      // the writers append to, so this label can never drift from where the logs
      // actually land. No trailing period: a path ends the line, so it can be
      // selected and copied without picking up punctuation — which is also why
      // the first path is followed by a plain space rather than a comma.
      Text(
        "Logs each dictation to \(DictationLog.defaultDisplayPath) "
          + "each failure to \(DictationLog.defaultErrorDisplayPath) "
          + "and Custom-capture input events to \(DictationLog.defaultCaptureDisplayPath)"
      )
      .textSelection(.enabled)
    }
  }
}

import SwiftUI

/// Scene identifier for the Prompt Inspector `Window` scene.
enum PromptInspectorWindow {
  static let id = "prompt-inspector"
}

/// Read-only view of the most recent assembled prompt (owned by `AppCoordinator`,
/// reached via the app delegate like the app's other windows). Opened from the
/// Window menu; closed with ⌘W. The text is selectable, so it copies with ⌘C —
/// no bespoke copy affordance needed. A plain window: no toolbar, no status bar.
struct PromptInspectorView: View {
  var appDelegate: AppDelegate

  private var lastPrompt: String? { appDelegate.coordinator?.lastPrompt }

  var body: some View {
    Group {
      if let prompt = lastPrompt {
        ScrollView {
          Text(prompt)
            .font(.system(.body, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
      } else {
        ContentUnavailableView(
          "No Prompt Captured",
          systemImage: "text.bubble",
          description: Text("Dictate once, then reopen this window."))
      }
    }
    .frame(minWidth: 480, minHeight: 360)
  }
}

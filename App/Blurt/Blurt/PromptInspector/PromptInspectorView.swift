import AppKit
import SwiftUI

/// Scene identifier for the Prompt Inspector `Window` scene.
enum PromptInspectorWindow {
  static let id = "prompt-inspector"
}

/// Read-only view of the most recent assembled prompt (owned by `AppCoordinator`,
/// reached via the app delegate like the app's other windows). Opened from the
/// Window menu; closed with ⌘W. Selectable + copyable so the text can be pasted
/// elsewhere.
struct PromptInspectorView: View {
  var appDelegate: AppDelegate

  private var lastPrompt: String? { appDelegate.coordinator?.lastPrompt }
  private var lastPromptSentAt: Date? { appDelegate.coordinator?.lastPromptSentAt }

  var body: some View {
    // No in-content title: the window title bar already reads "Prompt Inspector".
    // Copy lives in the titlebar toolbar (native placement) rather than floating
    // in the content; the timestamp sits in a bottom status bar.
    content
      .frame(minWidth: 480, minHeight: 360)
      .toolbar {
        ToolbarItem(placement: .primaryAction) {
          Button(action: copy) {
            Label("Copy", systemImage: "doc.on.doc")
          }
          .help("Copy the prompt to the clipboard")
          .disabled(lastPrompt == nil)
        }
      }
      // Give the titlebar a real material + separator so scrolled monospaced
      // text sits cleanly beneath it instead of bleeding into the title.
      .toolbarBackground(.visible, for: .windowToolbar)
  }

  @ViewBuilder private var content: some View {
    if let prompt = lastPrompt {
      VStack(spacing: 0) {
        ScrollView {
          Text(prompt)
            .font(.system(.body, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        statusBar
      }
    } else {
      // Distinguish "never dictated" (no timestamp) from "dictated, but the
      // context produced no prompt" (timestamp set, prompt nil).
      let neverCaptured = lastPromptSentAt == nil
      ContentUnavailableView(
        neverCaptured ? "No Prompt Captured" : "No Prompt Sent",
        systemImage: "text.bubble",
        description: Text(
          neverCaptured
            ? "Dictate once, then reopen this window."
            : "The last dictation had no context to build a prompt from."))
    }
  }

  @ViewBuilder private var statusBar: some View {
    if let sentAt = lastPromptSentAt {
      Divider()
      Text("Sent \(sentAt, format: .dateTime.month().day().hour().minute().second())")
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .accessibilityLabel("Prompt sent \(sentAt, format: .dateTime)")
    }
  }

  private func copy() {
    guard let prompt = lastPrompt else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(prompt, forType: .string)
  }
}

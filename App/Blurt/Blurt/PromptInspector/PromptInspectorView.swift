import AppKit
import SwiftUI

/// Scene identifier for the undocumented Prompt Inspector `Window` scene.
enum PromptInspectorWindow {
  static let id = "prompt-inspector"
}

/// Read-only view of the most recent assembled prompt. Opened from the Window
/// menu; closed with ⌘W. Selectable + copyable so the text can be pasted
/// elsewhere.
struct PromptInspectorView: View {
  @State private var inspector = PromptInspector.shared

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Prompt Inspector").font(.headline)
        Spacer()
        if let sentAt = inspector.lastSentAt {
          Text(sentAt, style: .time)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Button("Copy", action: copy)
          .disabled(inspector.lastPrompt == nil)
      }
      Divider()
      content
    }
    .padding(16)
    .frame(minWidth: 440, minHeight: 320)
  }

  @ViewBuilder private var content: some View {
    if let prompt = inspector.lastPrompt {
      ScrollView {
        Text(prompt)
          .font(.system(.body, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    } else {
      Text(
        inspector.lastSentAt == nil
          ? "No prompt captured yet — dictate once, then reopen."
          : "Last dictation sent no prompt (no context available)."
      )
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private func copy() {
    guard let prompt = inspector.lastPrompt else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(prompt, forType: .string)
  }
}

import Foundation
import Observation

/// Holds the fully-assembled prompt from the most recent dictation for the
/// undocumented Prompt Inspector window (opened with ⌃⌥⌘P). In-memory only — the
/// prompt can contain the user's prior transcript and on-screen selected text, so
/// it is never written to disk. Only the single most-recent prompt is retained.
@MainActor
@Observable
final class PromptInspector {
  static let shared = PromptInspector()
  private init() {}

  private(set) var lastPrompt: String?
  private(set) var lastSentAt: Date?

  /// Records the prompt from the latest dictation attempt. `nil` means the
  /// dictation produced no context prompt; `lastSentAt` still updates so the view
  /// can tell "no prompt this time" from "never dictated".
  func record(_ prompt: String?) {
    lastPrompt = prompt
    lastSentAt = Date()
  }
}

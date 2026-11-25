import Foundation
import Testing

@testable import BlurtEngine

/// The pill's VoiceOver label is spoken to the user, so lock the exact wording
/// of every case here — the AppKit shell reads these strings verbatim and a
/// silent edit would otherwise ship an unannounced regression.
@Suite("OverlayUIState.accessibilityLabel")
struct OverlayUIStateAccessibilityLabelTests {
  /// One row per fixed-wording state. `.error` is excluded: its label is a rule
  /// (echo the carried message verbatim), not a constant, so it keeps its own test.
  static let labels: [(state: OverlayUIState, spoken: String)] = [
    (.idle, "Blurt."),
    (.connecting, "Connecting to the microphone."),
    (.recording, "Recording."),
    (.processing, "Processing."),
    (.pasted, "Your dictation was pasted."),
    (.noTarget, "No text field focused. Your dictation was copied to the clipboard."),
  ]

  @Test("each state speaks its fixed label", arguments: labels)
  func stateSpeaksItsLabel(state: OverlayUIState, spoken: String) {
    #expect(state.accessibilityLabel == spoken)
  }

  @Test
  func errorLabelIsTheMessageVerbatim() {
    // The error case surfaces the failure reason directly as the spoken label,
    // so it must echo the message it carries with no wrapping.
    #expect(OverlayUIState.error(message: "AssemblyAI error 401.").accessibilityLabel == "AssemblyAI error 401.")
  }
}

import BlurtDesign
import BlurtiOSCore
import KeyboardKit
import SwiftUI

/// What the mic key shows — its legend; the cap, the press and the gestures
/// are KeyboardKit's, as for every key, and the press reaches
/// `BlurtActionHandler`. A plain glyph, as Apple's dictation key is: the mic
/// at rest, the live waveform while you talk (the level the app publishes),
/// a clipboard when the words went there, an exclamation mark on a failure;
/// dimmed when Blurt isn't ready (the tap opens Blurt), green while
/// recording, orange on a failure (`VoiceState`). Nothing snaps: every
/// change fades over `state-fade`.
struct MicKey: View {
  var model: BlurtiOSCore.KeyboardModel
  @EnvironmentObject private var keyboardContext: KeyboardContext

  var body: some View {
    let state = model.voiceState
    let scheme = keyboardContext.colorScheme
    Image(systemName: Self.symbol(for: state), variableValue: state.isRecording ? Double(state.level) : nil)
      .foregroundStyle(Self.tint(for: state, scheme: scheme))
      .opacity(state.dimmed ? DesignTokens.Metrics.opacityOff : 1)
      .accessibilityLabel(state.accessibilityLabel)
      .accessibilityValue(state.accessibilityValue)
      .accessibilityIdentifier("blurt-mic")
  }

  static func symbol(for state: VoiceState) -> String {
    switch state.glyph {
    case .clipboard: return "doc.on.clipboard"
    case .exclamation: return "exclamationmark"
    case nil: return state.isRecording ? "waveform" : "mic.fill"
    }
  }

  /// The key's own legend colour, unless the state has a colour of its own.
  static func tint(for state: VoiceState, scheme: ColorScheme) -> Color {
    switch state.ring {
    case .solid(.error): return BlurtTint.notice(scheme)
    case .solid(.ok): return BlurtTint.signal(scheme)
    case .still, .sweeping:
      if state.isRecording { return BlurtTint.signal(scheme) }
      return Color.keyboardDarkButtonForeground(for: scheme)
    }
  }
}

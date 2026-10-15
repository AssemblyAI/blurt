import BlurtEngine

/// What the voice control shows, from what the app published: one struct the
/// keyboard's key and the app's hero both draw from, so the two never tell a
/// different story. The keyboard builds it from the App Group's phase
/// snapshot, the app from the engine's overlay state; every visual decision
/// — the ring, a glyph, dimming, whether the meter is up — is a property here
/// and tested, not a branch in a view.
package nonisolated struct VoiceState: Equatable {
  /// The same states the keyboard reads from the App Group, so the keyboard's
  /// and the app's phases can't drift apart.
  package typealias Phase = PhaseSnapshot.State

  package enum Ring: Equatable {
    /// At rest, or while recording (the meter says it all).
    case still
    /// The mic coming up, the words being made.
    case sweeping
    /// A notice: green for the words landing, orange for a failure.
    case solid(Tone)
  }

  package enum Tone: Equatable {
    case ok
    case error
  }

  package enum Glyph: Equatable {
    case clipboard
    case exclamation
  }

  package let phase: Phase
  /// Whether a press can do anything but open the app: Full Access and the
  /// app listening (the keyboard), the mic window open (the app).
  package let isReady: Bool
  /// The voice level while recording, 0…1.
  package let level: Float
  /// The error's own words, for VoiceOver.
  package let message: String?

  package init(phase: Phase, isReady: Bool, level: Float = 0, message: String? = nil) {
    self.phase = phase
    self.isReady = isReady
    self.level = level
    self.message = message
  }

  /// The keyboard's: from the phase the app published.
  package init(snapshot: PhaseSnapshot, isReady: Bool) {
    self.init(phase: snapshot.state, isReady: isReady, level: Float(snapshot.level), message: snapshot.message)
  }

  /// The app's: from the engine's overlay state, mapped as the app publishes
  /// it to the keyboard.
  package init(overlay: OverlayUIState, windowOpen: Bool, level: Float) {
    let phase = Phase(overlay)
    self.init(
      phase: phase, isReady: windowOpen, level: phase == .recording ? level : 0,
      message: PhaseSnapshot.message(for: overlay))
  }

  /// The meter is up and is the key.
  package var isRecording: Bool { isReady && phase == .recording }

  /// Something is in flight: the mic coming up, the voice, the words being made.
  package var isWorking: Bool { isReady && !isSettled }

  package var isNotice: Bool { isSettled && phase != .idle }

  /// Nothing in flight — the moments the cancel control has nothing to cancel.
  package var isSettled: Bool { phase.isSettled }

  /// Something is in flight and Blurt is there to stop it: no × beside a
  /// dimmed mic whose app is gone.
  package var canCancel: Bool { !isSettled && isReady }

  package var ring: Ring {
    switch phase {
    case .error: return .solid(.error)
    case .pasted, .copied: return .solid(.ok)
    case .connecting, .processing: return isReady ? .sweeping : .still
    case .idle, .recording: return .still
    }
  }

  /// Only the two notices that need saying carry a glyph.
  package var glyph: Glyph? {
    guard isReady else { return nil }
    switch phase {
    case .copied: return .clipboard
    case .error: return .exclamation
    case .idle, .connecting, .recording, .processing, .pasted: return nil
    }
  }

  /// Blurt isn't ready: the control sits back, and a tap opens the app.
  package var dimmed: Bool { !isReady }

  package var accessibilityLabel: String {
    guard isReady else { return "Start Blurt" }
    return isRecording ? "Stop dictation" : "Dictate"
  }

  package var accessibilityValue: String {
    phase == .error ? message ?? "Dictation failed." : ""
  }
}

extension PhaseSnapshot.State {
  /// The engine's overlay state as the orb shows it. "No target" is the words
  /// going to the clipboard — the keyboard's "copied" — and a silent mic is an
  /// error: the iPhone has no wide pill for it.
  package init(_ overlay: OverlayUIState) {
    self =
      switch overlay {
      case .idle: .idle
      case .connecting: .connecting
      case .recording: .recording
      case .processing: .processing
      case .pasted: .pasted
      case .noTarget: .copied
      case .error, .inputSilent: .error
      }
  }
}

extension PhaseSnapshot {
  /// The words an overlay state carries for VoiceOver: an error's own, or the
  /// silent mic's sentence (with the device name).
  package static func message(for overlay: OverlayUIState) -> String? {
    switch overlay {
    case .error(let message): message
    case .inputSilent: overlay.accessibilityLabel
    case .idle, .connecting, .recording, .processing, .pasted, .noTarget: nil
    }
  }
}

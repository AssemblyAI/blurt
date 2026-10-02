import BlurtEngine

/// What the voice control shows, from what the app published: one struct the
/// keyboard's key and the app's hero both draw from, so the two never tell a
/// different story. The keyboard builds it from the App Group's phase
/// snapshot, the app from the engine's overlay state; every visual decision
/// — the ring, a glyph, dimming, whether the meter is up — is a property here
/// and tested, not a branch in a view.
package nonisolated struct VoiceState: Equatable {
  package enum Phase: Equatable {
    case idle
    case connecting
    case recording
    case processing
    case pasted
    case copied
    case error
  }

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
    let phase: Phase =
      switch snapshot.state {
      case .idle: .idle
      case .connecting: .connecting
      case .recording: .recording
      case .processing: .processing
      case .pasted: .pasted
      case .copied: .copied
      case .error: .error
      }
    self.init(phase: phase, isReady: isReady, level: Float(snapshot.level), message: snapshot.message)
  }

  /// The app's: from the engine's overlay state. "No target" is the words
  /// going to the clipboard — the keyboard's "copied".
  package init(overlay: OverlayUIState, windowOpen: Bool, level: Float) {
    switch overlay {
    case .idle: self.init(phase: .idle, isReady: windowOpen)
    case .connecting: self.init(phase: .connecting, isReady: windowOpen)
    case .recording: self.init(phase: .recording, isReady: windowOpen, level: level)
    case .processing: self.init(phase: .processing, isReady: windowOpen)
    case .pasted: self.init(phase: .pasted, isReady: windowOpen)
    case .noTarget: self.init(phase: .copied, isReady: windowOpen)
    case .error(let message): self.init(phase: .error, isReady: windowOpen, message: message)
    }
  }

  /// The meter is up and is the key.
  package var isRecording: Bool { isReady && phase == .recording }

  /// Something is in flight: the mic coming up, the voice, the words being made.
  package var isWorking: Bool {
    guard isReady else { return false }
    switch phase {
    case .connecting, .recording, .processing: return true
    case .idle, .pasted, .copied, .error: return false
    }
  }

  package var isNotice: Bool {
    switch phase {
    case .pasted, .copied, .error: true
    case .idle, .connecting, .recording, .processing: false
    }
  }

  /// Nothing in flight — the moments the cancel control has nothing to cancel.
  package var isSettled: Bool {
    switch phase {
    case .idle, .pasted, .copied, .error: true
    case .connecting, .recording, .processing: false
    }
  }

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

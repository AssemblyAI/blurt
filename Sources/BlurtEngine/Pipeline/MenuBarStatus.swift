/// The dictation state shown by the menu bar status item. Like `OverlayUIState`
/// it's a pure projection of `PipelinePhase`, owned in the engine so `swift test`
/// can cover the mapping (the AppKit/SwiftUI shell that draws the icon has no
/// test target). Coarser than `OverlayUIState`: the menu bar only distinguishes
/// idle / recording / transcribing and deliberately never shows the pill's
/// transient error flash, so a handled `.failed` reads as `.idle` here — which
/// also means the icon can't get stranded on a state the pill auto-reverts out
/// of band (its error flash is timer-driven, not a follow-up phase).
///
/// One state isn't a dictation phase: `.recordingAudio`, the main window's
/// Record button (or a meeting it auto-started) capturing the mic and Mac
/// audio. That capture can run with the window closed, so the menu bar is
/// where it stays visible (#345) — see `showing(recordingAudio:)`.
public enum MenuBarStatus: Equatable, Sendable {
  case idle
  case recording
  case transcribing
  case recordingAudio

  /// Template SF Symbol drawn in the menu bar. A stylized "B" (Blurt) at rest,
  /// filling in while recording — the same idle→fill idiom the mic glyphs used —
  /// and the waveform while transcribing. Owned here (not in the SwiftUI shell)
  /// for the same reason as the phase mapping below: the wording/glyph choices
  /// live in one unit-tested place, mirroring `OverlayUIState.accessibilityLabel`.
  public var symbolName: String {
    switch self {
    case .idle: "b.circle"
    case .recording: "b.circle.fill"
    case .transcribing: "waveform"
    case .recordingAudio: "record.circle"
    }
  }

  /// Spoken by VoiceOver, since the menu bar glyph is otherwise unlabelled.
  public var accessibilityLabel: String {
    switch self {
    case .idle: "Blurt — idle"
    case .recording: "Blurt — recording"
    case .transcribing: "Blurt — transcribing"
    case .recordingAudio: "Blurt — recording mic and Mac audio"
    }
  }

  /// This dictation status with a Record-button recording folded in: a
  /// dictation in progress wins (it's the brief, foreground thing), and
  /// otherwise a recording that's capturing shows — a paused one doesn't,
  /// for the same honesty rule that keeps `.connecting` idle.
  public func showing(recordingAudio isCapturing: Bool) -> MenuBarStatus {
    self == .idle && isCapturing ? .recordingAudio : self
  }
}

extension PipelinePhase {
  /// How this phase should be reflected on the menu bar status item.
  public var menuBarStatus: MenuBarStatus {
    switch self {
    case .recording: .recording
    case .transcribing: .transcribing
    // `.connecting` reads as idle: the filled glyph means "audio is being
    // captured", and during the mic bring-up it isn't yet — the same honesty
    // rule that holds the start chime. The pill carries the warming-up state,
    // and a distinct fourth glyph isn't worth it for something usually gone
    // within a frame on a wired mic.
    case .idle, .connecting, .injecting, .cancelled, .failed, .pasted, .noTarget, .handedBack: .idle
    }
  }
}

/// The dictation state shown by the menu bar status item. Like `OverlayUIState`
/// it's a pure projection of `PipelinePhase`, owned in the engine so `swift test`
/// can cover the mapping (the AppKit/SwiftUI shell that draws the icon has no
/// test target). Coarser than `OverlayUIState`: the menu bar only distinguishes
/// idle / recording / transcribing and deliberately never shows the pill's
/// transient error flash, so a handled `.failed` reads as `.idle` here — which
/// also means the icon can't get stranded on a state the pill auto-reverts out
/// of band (its error flash is timer-driven, not a follow-up phase).
public enum MenuBarStatus: Equatable, Sendable {
  case idle
  case recording
  case transcribing

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
    }
  }

  /// Spoken by VoiceOver, since the menu bar glyph is otherwise unlabelled.
  public var accessibilityLabel: String {
    switch self {
    case .idle: "Blurt — idle"
    case .recording: "Blurt — recording"
    case .transcribing: "Blurt — transcribing"
    }
  }
}

extension PipelinePhase {
  /// How this phase should be reflected on the menu bar status item.
  public var menuBarStatus: MenuBarStatus {
    switch self {
    case .recording: .recording
    case .transcribing: .transcribing
    case .idle, .injecting, .cancelled, .failed, .pasted, .noTarget: .idle
    }
  }
}

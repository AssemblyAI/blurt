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

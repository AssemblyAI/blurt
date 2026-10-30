/// When each pair of cue chimes reloads after the audio output route changed
/// under their pre-rolled players — the decision `CueSoundPlayer` carries out,
/// here where `swift test` covers it, as `RecordingCueGate` is for when a cue
/// plays.
///
/// Dictation's pair waits for the next press's `.connecting` (the route flip a
/// press causes lands then, one phase before the start chime it must protect)
/// or a terminal phase. Read-aloud's pair reloads straight away when nothing is
/// capturing — reads produce no pipeline phases, so waiting for one would leave
/// someone who only reads aloud with cues primed against the old route — and
/// otherwise at the end of the capture, so it never competes with a bring-up.
public struct CueReprimeSchedule: Sendable, Equatable {
  /// Which pairs to reload now.
  public struct Reloads: Sendable, Equatable {
    public let dictation: Bool
    public let readAloud: Bool

    public static let none = Reloads(dictation: false, readAloud: false)
  }

  private var dictationPending = false
  private var readAloudPending = false
  private var capturing = false

  public init() {}

  /// The output route changed.
  public mutating func routeChanged() -> Reloads {
    dictationPending = true
    guard capturing else { return Reloads(dictation: false, readAloud: true) }
    readAloudPending = true
    return .none
  }

  /// The session moved to `phase`.
  public mutating func phase(_ phase: PipelinePhase) -> Reloads {
    capturing = phase.isCapturing
    let dictation = dictationPending && (phase == .connecting || phase.isTerminal)
    let readAloud = readAloudPending && phase.isTerminal
    if dictation { dictationPending = false }
    if readAloud { readAloudPending = false }
    return Reloads(dictation: dictation, readAloud: readAloud)
  }
}

/// Decides **when** a host reloads its pre-rolled record-cue players after the
/// audio output route has moved underneath them.
///
/// A host pre-rolls its start/stop chimes once so the first one never stalls the
/// recording pill, and that pre-roll is bound to the output route it was made
/// against (see `AudioRouteMonitor` for what invalidates it — chiefly Blurt's own
/// capture flipping AirPods out of their output-only profile). Reloading is
/// therefore not optional; the only question is whether it happens now or waits,
/// and that question has exactly one wrong answer per side:
///
/// - Reload during live capture and the swap can land on a player that is
///   *sounding*, and two decodes land beside the mic bring-up.
/// - Reload *never* until the dictation ends and the very first chime of the
///   session is played through the stale pre-roll — the one chime the machinery
///   exists to protect. That was the shipped behaviour: the launch-time
///   warm-up's route flip left a re-prime pending, and the only thing that
///   consumed it was a terminal phase, which cannot arrive before the first
///   dictation's start chime.
///
/// So the rule is: **re-prime immediately unless the in-flight dictation's start
/// chime has already fired.** Idle (launch, a device switch, the warm recorder
/// expiring) re-primes on the spot, and so does the mic bring-up — `.connecting`
/// is a ~1–2 s window on a Bluetooth route where nothing is waiting on the
/// players and the chime that needs them is still ahead. Only from `.recording`
/// onwards is the reload held: by then the start chime has played (so the audio
/// queue is live against the current route anyway) and a swap could displace a
/// player mid-sound.
///
/// A value type holding two bits, driven by the same per-phase call the host
/// already makes for `RecordingCueGate`; the host owns one instance for its
/// lifetime. Lifted out of the AppKit player for the same reason as
/// `RecordingCueGate`: so `swift test` covers the timing rule rather than the
/// audio framework.
public struct CueReprimeGate: Sendable {
  /// True from the start chime having fired until the dictation ends — the one
  /// window a reload waits out.
  private var pastStartCue = false
  /// A route change that arrived inside that window, owed to the next terminal
  /// phase.
  private var held = false

  public init() {}

  /// Records one output-route change. `true` when the host should reload its cue
  /// players now; `false` when the reload is held for a later `phaseChanged(to:)`.
  public mutating func routeChanged() -> Bool {
    guard pastStartCue else {
      // Reloading now settles any earlier debt too — the fresh players are primed
      // against the live route, which is all a held reload would have bought.
      held = false
      return true
    }
    held = true
    return false
  }

  /// Records a phase the host just rendered, *after* it has played whatever cue
  /// that phase resolves to. `true` when a held reload has come due.
  public mutating func phaseChanged(to phase: PipelinePhase) -> Bool {
    // `.connecting` is deliberately on the "not yet" side of the start chime: the
    // press is what flips a Bluetooth route, so this is both the phase during
    // which the invalidating change arrives and the last chance to re-prime
    // before the chime it invalidates.
    pastStartCue = !phase.isTerminal && phase != .connecting
    guard phase.isTerminal, held else { return false }
    held = false
    return true
  }
}

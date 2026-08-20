import Testing

@testable import BlurtEngine

/// The cue players' pre-roll is bound to the output route it was made against,
/// so a route change owes a reload — and *when* that reload runs is the whole
/// bug this gate exists for. The shipped behaviour deferred every reload to the
/// next terminal phase, which by definition cannot arrive before the first
/// dictation's start chime: on a Bluetooth mic the launch-time warm-up flips the
/// output profile, so the very first chime of the session was the one played
/// through the stale pre-roll (audibly clipped), and every later one was fine.
@Suite("CueReprimeGate")
struct CueReprimeGateTests {
  @Test("a route change with nothing in flight re-primes immediately")
  func idleReprimesNow() {
    var gate = CueReprimeGate()
    #expect(gate.routeChanged())
  }

  @Test("the launch-time flip is re-primed before the first chime, not after it")
  func launchFlipReprimesBeforeFirstChime() {
    // The regression. `AppCoordinator.start()` warms the mic before the wizard's
    // ready transition primes the cues, and on AirPods that warm-up *is* an
    // output-route change — so the tick lands while the pipeline is idle, long
    // before any dictation. It must be acted on there; waiting for a terminal
    // phase spends the first start chime on the stale players.
    var gate = CueReprimeGate()
    #expect(gate.phaseChanged(to: .idle) == false)
    #expect(gate.routeChanged())
    // And nothing is still owed once the first dictation runs its course.
    #expect(gate.phaseChanged(to: .connecting) == false)
    #expect(gate.phaseChanged(to: .recording) == false)
    #expect(gate.phaseChanged(to: .pasted) == false)
  }

  @Test("a flip during the mic bring-up re-primes inside that window")
  func connectingReprimesNow() {
    // The other half of the same bug, and the case with no warm recorder: the
    // press itself opens the mic, so the profile flip arrives during
    // `.connecting`. That phase is a ~1–2 s Bluetooth window with nothing
    // waiting on the players and the start chime still ahead of it — exactly
    // when the reload is both free and useful.
    var gate = CueReprimeGate()
    #expect(gate.phaseChanged(to: .connecting) == false)
    #expect(gate.routeChanged())
  }

  @Test("a flip once the start chime has fired is held until the dictation ends")
  func midCaptureReprimeIsHeld() {
    // Past the start chime the audio queue is already live against the current
    // route, and a swap could displace a player mid-sound — so this one waits,
    // which is the behaviour the deferral was written for.
    var gate = CueReprimeGate()
    #expect(gate.phaseChanged(to: .connecting) == false)
    #expect(gate.phaseChanged(to: .recording) == false)
    #expect(gate.routeChanged() == false)
    #expect(gate.phaseChanged(to: .transcribing) == false)
    #expect(gate.phaseChanged(to: .injecting) == false)
    #expect(gate.phaseChanged(to: .pasted))
  }

  @Test("a held reload comes due exactly once")
  func heldReloadFiresOnce() {
    var gate = CueReprimeGate()
    #expect(gate.phaseChanged(to: .recording) == false)
    #expect(gate.routeChanged() == false)
    #expect(gate.phaseChanged(to: .idle))
    #expect(gate.phaseChanged(to: .idle) == false)
  }

  @Test("a burst of flips during one capture coalesces into a single reload")
  func burstCoalesces() {
    var gate = CueReprimeGate()
    #expect(gate.phaseChanged(to: .recording) == false)
    #expect(gate.routeChanged() == false)
    #expect(gate.routeChanged() == false)
    #expect(gate.routeChanged() == false)
    #expect(gate.phaseChanged(to: .pasted))
    #expect(gate.phaseChanged(to: .idle) == false)
  }

  @Test("an immediate re-prime settles a debt held from the previous capture")
  func immediateReprimeClearsHeldDebt() {
    // A flip mid-capture is held; a second flip after the capture ends re-primes
    // on the spot. The fresh players are primed against the live route, so the
    // held reload has nothing left to buy and must not fire a second decode at
    // the next terminal phase.
    var gate = CueReprimeGate()
    #expect(gate.phaseChanged(to: .recording) == false)
    #expect(gate.routeChanged() == false)
    #expect(gate.phaseChanged(to: .connecting) == false)
    #expect(gate.routeChanged())
    #expect(gate.phaseChanged(to: .recording) == false)
    #expect(gate.phaseChanged(to: .pasted) == false)
  }

  @Test("a press whose mic never comes up leaves nothing held")
  func failedBringUpSettles() {
    // `.connecting` → `.failed` never reaches the start chime, so a flip during
    // the bring-up was already re-primed on the spot and the terminal phase owes
    // nothing.
    var gate = CueReprimeGate()
    #expect(gate.phaseChanged(to: .connecting) == false)
    #expect(gate.routeChanged())
    let failure = PipelinePhase.failed(.audioCaptureFailed(underlying: MicCaptureError.noInputDevice))
    #expect(gate.phaseChanged(to: failure) == false)
  }

  @Test("every terminal phase releases a held reload")
  func allTerminalPhasesRelease() {
    let terminal: [PipelinePhase] = [
      .idle, .cancelled, .pasted, .noTarget, .failed(.apiKeyMissing),
    ]
    for phase in terminal {
      var gate = CueReprimeGate()
      #expect(gate.phaseChanged(to: .recording) == false)
      #expect(gate.routeChanged() == false)
      #expect(gate.phaseChanged(to: phase), "\(phase) should release the held reload")
    }
  }

  @Test("no route change means no reload, however the phases move")
  func noChangeNoReload() {
    var gate = CueReprimeGate()
    let cycle: [PipelinePhase] = [
      .idle, .connecting, .recording, .transcribing, .injecting, .pasted, .idle,
    ]
    for phase in cycle {
      #expect(gate.phaseChanged(to: phase) == false)
    }
  }
}

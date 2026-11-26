import AVFoundation
import BlurtEngine

/// Owns the cue chimes — a start/stop `CuePair` per trigger key, each from that
/// key's voice (`TriggerKeySoundStore.soundPack(for:)`): loading the selected
/// pack, pre-rolling so the first chime never stalls the pill, previewing on a
/// pack change, and firing on the recording edge or a read's start and end, in
/// the voice of the key that started it. Kept out of `AppCoordinator`'s body so
/// chime behavior can change without churning the session↔UI wiring.
final class CueSoundPlayer {
  private let pairs: [TriggerKey: CuePair] = Dictionary(
    uniqueKeysWithValues: TriggerKey.allCases.map { key in
      (key, CuePair { TriggerKeySoundStore().soundPack(for: key) })
    }
  )
  /// The key whose press came last (`keyPressed(_:)`): the voice the next
  /// recording or read starts in. The bound key until a press says otherwise.
  private var pressedKey = TriggerKeyStore().triggerKey
  /// The key a recording's start cue played for, so its stop cue matches even
  /// if another key is pressed before it lands.
  private var recordingKey: TriggerKey?
  /// The same for a read, between `speechStarted()` and `speechEnded()`.
  private var speakingKey: TriggerKey?
  /// Edge-detector deciding when the start/stop chimes fire. The mapping from a
  /// pipeline phase to a cue lives in the engine (`RecordingCueGate`), where
  /// `swift test` covers it; this player just plays whatever it resolves to.
  private var cueGate = RecordingCueGate()
  /// When each pair reloads after an output-route change (the engine's
  /// `CueReprimeSchedule`; see `transition(for:)` for why dictation's waits).
  private var reprime = CueReprimeSchedule()
  /// Fires when the output route changes under the pre-rolled players. Blurt's
  /// own capture is the usual cause: opening the mic flips AirPods out of their
  /// output-only profile, which drops the output format the players were primed
  /// against — so the very next chime is the one that stalls, and that's the
  /// chime at the start of a dictation.
  ///
  /// Kept alive for the app's lifetime; assignment is the use. Nil until
  /// `prime()` starts it, which is also what makes starting idempotent.
  private var routeObserver: Task<Void, Never>?

  /// Constructs the monitor off the main actor. `nonisolated` + `async` for the
  /// same reason `decode` is: this type defaults to `MainActor`, so a plain
  /// initializer call would run on the main thread — and constructing it
  /// registers two CoreAudio listeners and makes the process's *first* HAL call,
  /// paying the client-side HAL init and the coreaudiod connection. As a stored
  /// property that landed during launch, before the first frame, on every run
  /// including onboarding and UI tests where no chime is ever played.
  @concurrent
  nonisolated private static func makeRouteMonitor() async -> AudioRouteMonitor {
    AudioRouteMonitor()
  }

  /// (Re)loads and pre-rolls the cue players for the selected sound pack so
  /// the first start/stop chime adds no latency to the pill; called from the
  /// "app is ready" transition, well before the hot path. `.none` (or a
  /// missing file) leaves a player nil, which `play(_:)` skips. Idempotent and
  /// genuinely cheap on repeat: the decoded players are cached per pack, so a
  /// re-prime for the already-loaded pack returns immediately instead of
  /// re-decoding the AAC. A real pack switch flows through `packChanged()` with a
  /// new selection, so `CuePair.load` reloads.
  ///
  /// Fire-and-forget: the actual decode runs off the main actor (see `decode`) and
  /// nothing waits on it — the players only need to be ready before the *first
  /// dictation*, which is always well after this launch-time call, so the AAC
  /// decode never sits on the main thread during startup.
  func prime() {
    refresh()
    startObservingRoute()
  }

  /// Loads any key whose voice changed under it — a new action moves a key
  /// with no voice of its own to that action's. Cheap when nothing did: each
  /// pair skips a load of the pack it already holds.
  func refresh() {
    Task {
      for key in TriggerKey.allCases { await pairs[key]?.load() }
    }
  }

  /// A trigger key's press started something; its voice is the next one heard.
  func keyPressed(_ key: TriggerKey) {
    pressedKey = key
  }

  /// Re-primes the players whenever the output route changes, so the pre-roll
  /// `prime()` bought at launch survives a device switch or a profile flip.
  /// Idempotent — `prime()` runs on every "app is ready" transition, and only
  /// the first call installs the observer.
  ///
  /// A full reload rather than a bare `prepareToPlay()`: re-creating the players
  /// is the one thing guaranteed to leave them primed against the *current*
  /// route, and the decode runs off the main actor like every other load. Route
  /// changes are not rare — on a Bluetooth output Blurt's own capture causes one
  /// per dictation burst — which is exactly why the reload is deferred rather
  /// than run on the tick; see `transition(for:)`.
  private func startObservingRoute() {
    guard routeObserver == nil else {
      return
    }
    routeObserver = Task { [weak self] in
      // The monitor is owned by this task, not stored: the local keeps it alive
      // for as long as the loop runs, and dropping it when the task ends is what
      // deregisters its CoreAudio listeners.
      let monitor = await Self.makeRouteMonitor()
      for await _ in monitor.outputRouteChanges {
        // Rebound per tick rather than bound once above, so the observer never
        // keeps the player alive — the same reason `MicCapture`'s meter task
        // rebinds across its sleep.
        guard let self else {
          return
        }
        reload(reprime.routeChanged())
      }
    }
  }

  /// Previews `key`'s newly selected pack (`CuePair.preview`).
  func packChanged(for key: TriggerKey) {
    Task { await pairs[key]?.preview() }
  }

  /// Fires the start/stop cue on the recording edge, in the voice of the key
  /// whose press started the recording. Call once per rendered phase; only the
  /// idle↔recording transitions make a sound (the edge logic is the engine's
  /// `RecordingCueGate`).
  func transition(for phase: PipelinePhase) {
    switch cueGate.cue(for: phase) {
    case .start:
      recordingKey = pressedKey
      pairs[pressedKey]?.playStart()

    case .stop:
      pairs[recordingKey ?? pressedKey]?.playStop()
      recordingKey = nil

    case nil:
      break
    }
    // A pending route re-prime is acted on at exactly two points.
    //
    // `.connecting` covers the re-prime that is *already pending when a press
    // arrives*, which is the one the user hears: opening the mic flips AirPods
    // out of their output-only profile, which invalidates the players `prime()`
    // pre-rolled, and the first start chime after such a flip is the one that
    // stalls or clips. That flip lands at the *press* — `record()`'s
    // `startRunning()` is what opens the device, and nothing before it does (see
    // `MicCapture.warmUp()`, which deliberately holds no open input) — so a
    // pending re-prime and the chime it has to protect are one phase apart.
    // Waiting for a terminal phase meant that reload landed *after* the
    // dictation it should have protected. Reloading here is safe where reloading
    // mid-press was not:
    // no cue is in flight in this phase (the start chime rides the
    // connecting→recording edge), so nothing is swapped out from under a playing
    // `AVAudioPlayer`; the decode runs off the main actor, so it isn't competing
    // with the bring-up for the main thread; and the liveness gate holds
    // `.connecting` for up to `MicLiveness.bluetoothTimeout` on the route that
    // needs this most, which is real time for the reload to land in.
    //
    // Terminal phases stay a trigger for everything else. A flip caused by *this*
    // press arrives mid-bring-up, too late for this dictation's chime either way,
    // and between dictations the reload costs nothing anyone is waiting on and
    // coalesces a burst of flips into one decode. Read-aloud's pair reloads at
    // once when nothing is capturing (reads produce no phases to wait for),
    // else at the capture's end, so it never competes with a bring-up.
    reload(reprime.phase(phase))
  }

  /// Reloads the pairs `reloads` names, each against the current route. The
  /// schedule's two halves are the keys that record (cued on capture edges)
  /// and the keys that speak (cued around a read); an ask key does both.
  private func reload(_ reloads: CueReprimeSchedule.Reloads) {
    let bindings = TriggerKeyBindings()
    let keys = TriggerKey.allCases.filter { key in
      let action = bindings.action(for: key)
      return (reloads.dictation && action.records) || (reloads.readAloud && action.speaks)
    }
    guard !keys.isEmpty else {
      return
    }
    Task {
      for key in keys { await pairs[key]?.load(force: true) }
    }
  }

  /// A read's start and stop, in the voice of the key that asked for it.
  func speechStarted() {
    speakingKey = pressedKey
    pairs[pressedKey]?.playStart()
  }

  func speechEnded() {
    pairs[speakingKey ?? pressedKey]?.playStop()
    speakingKey = nil
  }

  /// The player is owned for the whole app session, so this never runs in
  /// practice — but cancelling the observer mirrors the `[weak self]` care below
  /// and documents that its lifetime is owned rather than leaked.
  deinit {
    routeObserver?.cancel()
  }
}

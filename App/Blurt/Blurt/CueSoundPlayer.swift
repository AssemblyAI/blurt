import AVFoundation
import BlurtEngine

/// Owns the record start/stop cue chimes: loading the selected pack, pre-rolling
/// so the first chime never stalls the recording pill, previewing on a pack
/// change, and firing on the recording edge. Kept out of `AppCoordinator`'s body
/// so chime behavior can change without churning the session↔UI wiring.
final class CueSoundPlayer {
  private var startSound: AVAudioPlayer?
  private var stopSound: AVAudioPlayer?
  /// The pack the current `startSound`/`stopSound` were decoded from, so `prime()`
  /// can skip re-decoding when nothing changed. `nil` until the first load.
  private var loadedPack: SoundPack?
  /// Edge-detector deciding when the start/stop chimes fire. The mapping from a
  /// pipeline phase to a cue lives in the engine (`RecordingCueGate`), where
  /// `swift test` covers it; this player just plays whatever it resolves to.
  private var cueGate = RecordingCueGate()

  /// The cues are deliberate UI accents, not music — they are normalized to a
  /// hot peak, so play them well below full scale so they read as a soft chime
  /// rather than blasting at the system output level.
  private nonisolated static let cueVolume: Float = 0.35

  /// (Re)loads and pre-rolls the cue players for the selected sound pack so
  /// the first start/stop chime adds no latency to the pill; called from the
  /// "app is ready" transition, well before the hot path. `.none` (or a
  /// missing file) leaves a player nil, which `play(_:)` skips. Idempotent and
  /// genuinely cheap on repeat: the decoded players are cached per pack, so a
  /// re-prime for the already-loaded pack returns immediately instead of
  /// re-decoding the AAC. A real pack switch flows through `packChanged()` with a
  /// new selection, so `loadCurrentPack` reloads.
  ///
  /// Fire-and-forget: the actual decode runs off the main actor (see `decode`) and
  /// nothing waits on it — the players only need to be ready before the *first
  /// dictation*, which is always well after this launch-time call, so the AAC
  /// decode never sits on the main thread during startup.
  func prime() {
    Task { await loadCurrentPack() }
  }

  /// Reloads the players for a newly selected pack and previews the new voice
  /// (start, then stop a beat apart) so the choice is audible immediately —
  /// after the reload lands, so the preview uses the freshly decoded players.
  /// Silent for the `.none` pack (all players are nil, which `play(_:)` skips).
  func packChanged() {
    Task {
      await loadCurrentPack()
      play(startSound)
      try? await Task.sleep(for: .milliseconds(380))
      play(stopSound)
    }
  }

  /// Decodes and installs the cue players for the current selection if they aren't
  /// already loaded. The `loadedPack` guard makes repeat calls cheap; the decode
  /// itself hops off the main actor. Returns once the players are assigned.
  private func loadCurrentPack() async {
    let pack = SoundPackStore().soundPack
    guard pack != loadedPack else { return }
    loadedPack = pack
    let players = await Self.decode(pack)
    // Re-check after the off-actor decode: if a newer selection was claimed while
    // we were decoding (rapid pack switches), its decode owns the players now —
    // dropping this stale result avoids installing players that disagree with
    // `loadedPack`. `loadedPack` is written synchronously above (no await between
    // read and write), so only the newest-requested load passes this guard.
    guard loadedPack == pack else { return }
    startSound = players.start
    stopSound = players.stop
  }

  /// Fires the start/stop cue on the recording edge. Call once per rendered
  /// phase; only the idle↔recording transitions make a sound (the edge logic is
  /// the engine's `RecordingCueGate`).
  func transition(for phase: PipelinePhase) {
    switch cueGate.cue(for: phase) {
    case .start: play(startSound)
    case .stop: play(stopSound)
    case nil: break
    }
  }

  /// The decoded, pre-rolled players for a pack. Non-`Sendable` (holds
  /// `AVAudioPlayer`), so `decode` hands it back via `sending`. `nonisolated` so it
  /// can be built inside the off-main `decode` (the app defaults to MainActor
  /// isolation, which would otherwise pin its init to the main actor).
  private nonisolated struct CuePlayers {
    let start: AVAudioPlayer?
    let stop: AVAudioPlayer?
  }

  /// Decodes and pre-rolls the pack's cue players. `nonisolated` + `async` so it
  /// runs off the main actor — `AVAudioPlayer(contentsOf:)` decodes the AAC up
  /// front and `prepareToPlay()` primes the audio queue, the two costs we're
  /// keeping off the main thread. `sending` lets the freshly created (non-Sendable)
  /// players cross back to the caller's actor for assignment.
  private nonisolated static func decode(_ pack: SoundPack) async -> sending CuePlayers {
    let start = pack.startFileName.flatMap(bundledSound(named:))
    let stop = pack.stopFileName.flatMap(bundledSound(named:))
    start?.volume = cueVolume
    stop?.volume = cueVolume
    start?.prepareToPlay()
    stop?.prepareToPlay()
    return CuePlayers(start: start, stop: stop)
  }

  /// Loads a bundled chime (`Resources/Sounds/<name>.m4a`) fully into memory:
  /// `AVAudioPlayer(contentsOf:)` decodes the AAC up front, unlike
  /// `NSSound(…byReference: true)`, whose deferred disk read stalled the pill
  /// on the first dictation. `decode` then pre-rolls the audio queue too.
  private nonisolated static func bundledSound(named name: String) -> AVAudioPlayer? {
    guard let url = Bundle.main.url(forResource: name, withExtension: "m4a") else { return nil }
    return try? AVAudioPlayer(contentsOf: url)
  }

  /// Plays a cue from the start, without ever blocking the caller. Rewinding
  /// first means a cue replays cleanly even if the previous play hasn't been
  /// reset, and keeping this off the visual path (callers reveal the pill
  /// first) guarantees the sound never delays the overlay.
  private func play(_ sound: AVAudioPlayer?) {
    guard let sound else { return }
    sound.currentTime = 0
    sound.play()
  }
}

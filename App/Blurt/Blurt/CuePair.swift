import AVFoundation
import BlurtEngine

/// One key's start/stop chimes: where its pack comes from, the decoded
/// players, and the load that keeps them current.
final class CuePair {
  /// The decoded, pre-rolled players for a pack. Non-`Sendable` (holds
  /// `AVAudioPlayer`), so `decode` hands it back via `sending`. `nonisolated` so it
  /// can be built inside the off-main `decode` (the app defaults to MainActor
  /// isolation, which would otherwise pin its init to the main actor).
  nonisolated private struct CuePlayers {
    let start: AVAudioPlayer?
    let stop: AVAudioPlayer?
  }

  /// The beat between a preview's start and stop chimes.
  private static let previewGap = Duration.milliseconds(380)

  /// The cues are deliberate UI accents, not music — they are normalized to a
  /// hot peak, so play them well below full scale so they read as a soft chime
  /// rather than blasting at the system output level.
  nonisolated private static let cueVolume: Float = 0.35

  /// Reads the key's current pack — re-read on every load, so a changed voice
  /// or action is picked up without rebuilding the pair.
  private let currentPack: () -> SoundPack
  private var start: AVAudioPlayer?
  private var stop: AVAudioPlayer?
  /// The pack the current players were decoded from, so a repeat load can skip
  /// re-decoding when nothing changed. `nil` until the first load.
  private var loaded: SoundPack?
  /// Monotonic ticket for in-flight decodes: only the newest one installs its
  /// players. This is the staleness check, **not** `loaded` equality — which
  /// cannot discriminate two loads of the *same* pack, and a route change forces
  /// exactly that. Without it, a decode already in flight when the route changed
  /// could land after the re-prime and install players primed against the old
  /// output route — the stall the re-prime exists to prevent.
  private var generation = 0

  init(currentPack: @escaping () -> SoundPack) {
    self.currentPack = currentPack
  }

  /// Decodes and pre-rolls the pack's cue players. `nonisolated` + `async` so it
  /// runs off the main actor — `AVAudioPlayer(contentsOf:)` decodes the AAC up
  /// front and `prepareToPlay()` primes the audio queue, the two costs we're
  /// keeping off the main thread. `sending` lets the freshly created (non-Sendable)
  /// players cross back to the caller's actor for assignment.
  @concurrent
  nonisolated private static func decode(_ pack: SoundPack) async -> sending CuePlayers {
    let startPlayer = pack.startFileName.flatMap(bundledSound(named:))
    let stopPlayer = pack.stopFileName.flatMap(bundledSound(named:))
    startPlayer?.volume = cueVolume
    stopPlayer?.volume = cueVolume
    startPlayer?.prepareToPlay()
    stopPlayer?.prepareToPlay()
    return CuePlayers(start: startPlayer, stop: stopPlayer)
  }

  /// Loads a bundled chime (`Resources/Sounds/<name>.m4a`) fully into memory:
  /// `AVAudioPlayer(contentsOf:)` decodes the AAC up front, unlike
  /// `NSSound(…byReference: true)`, whose deferred disk read stalled the pill
  /// on the first dictation. `decode` then pre-rolls the audio queue too.
  nonisolated private static func bundledSound(named name: String) -> AVAudioPlayer? {
    guard let url = Bundle.main.url(forResource: name, withExtension: "m4a") else {
      return nil
    }
    return try? AVAudioPlayer(contentsOf: url)
  }

  /// Plays a cue from the start, without ever blocking the caller. Rewinding
  /// first means a cue replays cleanly even if the previous play hasn't been
  /// reset, and keeping this off the visual path (callers reveal the pill
  /// first) guarantees the sound never delays the overlay.
  private static func play(_ sound: AVAudioPlayer?) {
    guard let sound else {
      return
    }
    sound.currentTime = 0
    sound.play()
  }

  /// Decodes and installs the players for the current selection if they aren't
  /// already loaded. The decode itself hops off the main actor. Returns once
  /// the players are assigned. `force` skips the already-loaded short-circuit,
  /// for a re-prime where the selection is unchanged and only the output route
  /// moved.
  func load(force: Bool = false) async {
    let pack = currentPack()
    guard force || pack != loaded else {
      return
    }
    generation += 1
    let ticket = generation
    loaded = pack
    let players = await Self.decode(pack)
    // Re-check after the off-actor decode: whoever asked last owns the players.
    // Both are written synchronously above (no await between read and write), so
    // exactly one in-flight decode passes this guard — the newest. Ticketed
    // rather than compared against `loaded`, so two loads of the same pack (a
    // rapid pack switch back, or any forced route re-prime) can still tell
    // each other apart.
    guard ticket == generation else {
      return
    }
    start = players.start
    stop = players.stop
  }

  /// Reloads for a newly selected pack and previews it (start, then stop a beat
  /// apart) so the choice is audible immediately — after the reload lands, so
  /// the preview uses the freshly decoded players. Silent for `.none` (both
  /// players are nil, which `play(_:)` skips).
  func preview() async {
    await load()
    playStart()
    try? await Task.sleep(for: Self.previewGap)
    playStop()
  }

  func playStart() { Self.play(start) }
  func playStop() { Self.play(stop) }
}

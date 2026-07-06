import AVFoundation
import BlurtEngine

/// Owns the record start/stop cue chimes: loading the selected pack, pre-rolling
/// so the first chime never stalls the recording pill, previewing on a pack
/// change, and firing on the recording edge. Kept out of `AppCoordinator`'s body
/// so chime behavior can change without churning the session↔UI wiring.
final class CueSoundPlayer {
  private var startSound: AVAudioPlayer?
  private var stopSound: AVAudioPlayer?
  private var wasRecording = false

  /// The cues are deliberate UI accents, not music — they are normalized to a
  /// hot peak, so play them well below full scale so they read as a soft chime
  /// rather than blasting at the system output level.
  private static let cueVolume: Float = 0.35

  /// (Re)loads and pre-rolls the cue players for the selected sound pack so
  /// the first start/stop chime adds no latency to the pill; called from the
  /// "app is ready" transition, well before the hot path. `.none` (or a
  /// missing file) leaves a player nil, which `play(_:)` skips. Idempotent:
  /// re-priming an already-prepared player is cheap.
  func prime() {
    let pack = SoundPackStore().soundPack
    startSound = pack.startFileName.flatMap(Self.bundledSound(named:))
    stopSound = pack.stopFileName.flatMap(Self.bundledSound(named:))
    startSound?.volume = Self.cueVolume
    stopSound?.volume = Self.cueVolume
    startSound?.prepareToPlay()
    stopSound?.prepareToPlay()
  }

  /// Reloads the players for a newly selected pack and previews the new voice
  /// (start, then stop a beat apart) so the choice is audible immediately.
  /// Silent for the `.none` pack (all players are nil, which `play(_:)` skips).
  func packChanged() {
    prime()
    play(startSound)
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(380))
      play(stopSound)
    }
  }

  /// Fires the start/stop cue on the recording edge. Call once per rendered
  /// phase; only the idle↔recording transitions make a sound.
  func transition(isRecording: Bool) {
    if isRecording && !wasRecording {
      play(startSound)
    } else if !isRecording && wasRecording {
      play(stopSound)
    }
    wasRecording = isRecording
  }

  /// Loads a bundled chime (`Resources/Sounds/<name>.m4a`) fully into memory:
  /// `AVAudioPlayer(contentsOf:)` decodes the AAC up front, unlike
  /// `NSSound(…byReference: true)`, whose deferred disk read stalled the pill
  /// on the first dictation. `prime()` then pre-rolls the audio queue too.
  private static func bundledSound(named name: String) -> AVAudioPlayer? {
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

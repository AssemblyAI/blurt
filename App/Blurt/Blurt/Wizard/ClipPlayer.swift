import AVFoundation
import Foundation
import Observation

/// Plays one saved clip at a time from the history — a read-aloud clip, a
/// recording, or a file — and says which is playing, so a row and the sheet
/// can show Play or Stop for it. Starting another clip stops the first.
@Observable
final class ClipPlayer: NSObject, AVAudioPlayerDelegate {
  /// The history entry whose audio is playing now; nil when nothing is. An
  /// id, not the file's URL: a row asking "is that me?" then needn't resolve
  /// its bookmark to find out.
  private(set) var playingID: UUID?
  @ObservationIgnored private var player: AVAudioPlayer?

  /// Plays `url` for entry `id`, or stops it if that entry is playing. A file
  /// that can't be opened (moved, deleted) simply doesn't play.
  func toggle(_ url: URL, id: UUID) {
    if playingID == id {
      stop()
      return
    }
    stop()
    guard let player = try? AVAudioPlayer(contentsOf: url) else { return }
    player.delegate = self
    guard player.play() else { return }
    self.player = player
    playingID = id
  }

  func stop() {
    player?.stop()
    player = nil
    playingID = nil
  }

  nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
    // Compared by identity on the main actor; the player itself never crosses.
    let finished = ObjectIdentifier(player)
    Task { @MainActor in
      guard let current = self.player, ObjectIdentifier(current) == finished else { return }
      self.stop()
    }
  }
}

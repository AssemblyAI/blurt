import AVFoundation
import Foundation
import Observation

/// Plays one saved clip at a time from the history — a read-aloud clip, a
/// recording, or a file — and says which is playing, so a row and the sheet
/// can show Play or Stop for it. Starting another clip stops the first.
@Observable
final class ClipPlayer: NSObject, AVAudioPlayerDelegate {
  /// The file playing now; nil when nothing is.
  private(set) var playingURL: URL?
  @ObservationIgnored private var player: AVAudioPlayer?

  /// Plays `url`, or stops it if it's the one playing. A file that can't be
  /// opened (moved, deleted) simply doesn't play.
  func toggle(_ url: URL) {
    if playingURL == url {
      stop()
      return
    }
    stop()
    guard let player = try? AVAudioPlayer(contentsOf: url) else { return }
    player.delegate = self
    guard player.play() else { return }
    self.player = player
    playingURL = url
  }

  func stop() {
    player?.stop()
    player = nil
    playingURL = nil
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

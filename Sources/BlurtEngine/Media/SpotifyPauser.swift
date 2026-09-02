import Dispatch
import Synchronization

/// Pauses Spotify while a dictation is in flight and resumes it when the
/// dictation ends — pasted, copied, failed, or cancelled — but **only when
/// Blurt was the one that paused it**: a Spotify the user had paused (or never
/// had playing) is left alone. Opt-in via `SpotifyPauseStore` (off by default),
/// and the switch is checked before anything else, so an install that never
/// opts in never sends a single Apple Event — which is also what keeps macOS's
/// one-time Automation prompt ("Blurt wants to control Spotify", raised by the
/// first event a process sends) away from users who never asked for this.
///
/// Both entry points are fire-and-forget onto a private serial queue: Apple
/// Events are synchronous cross-process IPC into Spotify, bounded only by the
/// Apple Event timeout, so a hung Spotify must cost one Dispatch thread — never
/// the caller, the main thread, or the cooperative pool (the reasoning on
/// `DictationSession.contextQueue`). Nothing on the press-to-record path ever
/// awaits this type.
public final class SpotifyPauser: Sendable {
  /// What Spotify reports for `player state`, decoded from the AppleScript
  /// enumeration's text form (see `Client.playerState` in `+Live`).
  enum PlayerState: String, Sendable {
    case playing, paused, stopped
  }

  /// Whether the last `dictationBegan()` paused Spotify — the state the whole
  /// type exists to track: a resume is owed only when Blurt did the pausing.
  private let pausedByUs = Mutex(false)
  private let client: Client
  private let isEnabled: @Sendable () -> Bool
  /// Serial, so a dictation's pause always lands before its resume — the host
  /// hands us the phases in order, and this keeps them in order across the hop.
  private let queue = DispatchQueue(
    label: HostIdentity.current.queueLabel("SpotifyPause"), qos: .userInitiated)

  /// The real Spotify client and the Settings switch — what the app uses.
  public convenience init() {
    self.init(client: .production)
  }

  /// Seam-injected for tests (see `Client`). `isEnabled` defaults to the
  /// Settings switch so `SpotifyPauseStore.isEnabled` keeps a production
  /// reader; it is a closure so each dictation re-reads the toggle.
  init(
    client: Client,
    isEnabled: @escaping @Sendable () -> Bool = { SpotifyPauseStore().isEnabled }
  ) {
    self.client = client
    self.isEnabled = isEnabled
  }

  /// Call once per dictation, when the press is accepted. Fire-and-forget:
  /// returns immediately, the Spotify work runs on the pauser's own queue.
  public func dictationBegan() {
    queue.async { self.pauseIfPlaying() }
  }

  /// Call on every terminal phase. Fire-and-forget, and free when nothing is
  /// owed (the flag is read before Spotify is so much as looked at), so hosts
  /// can call it for every terminal render — including the initial `.idle`.
  public func dictationEnded() {
    queue.async { self.resumeIfPaused() }
  }

  /// The decision half of `dictationBegan()`, synchronous for the unit tests.
  /// `isEnabled` is checked before the client is touched, and `isRunning`
  /// (a process-list read, not an Apple Event) before `playerState` (which is
  /// one) — so the opted-out and the no-Spotify cases send nothing.
  func pauseIfPlaying() {
    pausedByUs.withLock { $0 = false }
    guard isEnabled(), client.isRunning() else { return }
    switch client.playerState() {
    case .playing:
      client.pause()
      pausedByUs.withLock { $0 = true }
    case .paused, .stopped, nil:
      // Nothing playing (or the state was unreadable — a denied Automation
      // prompt reads as nil): nothing to pause, and nothing owed at the end.
      break
    }
  }

  /// The decision half of `dictationEnded()`. Resumes only when the matching
  /// begin paused Spotify and it is still running; the flag is consumed either
  /// way, so a resume happens at most once per pause. Deliberately no second
  /// `player state` query: when the user already resumed by hand, `play` is a
  /// no-op, which is simpler than telling that apart from every other state
  /// Spotify can reach mid-dictation.
  func resumeIfPaused() {
    let owed = pausedByUs.withLock { paused in
      let was = paused
      paused = false
      return was
    }
    guard owed, client.isRunning() else { return }
    client.play()
  }
}

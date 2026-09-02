import Dispatch
import Synchronization

/// Pauses the music players (Spotify and Apple Music) while a dictation is in
/// flight and resumes them when the dictation ends — pasted, copied, failed, or
/// cancelled — but **only the players Blurt itself paused**: a player the user
/// had paused (or never had playing) is left alone. Opt-in via `MediaPauseStore`
/// (off by default), and the switch is checked before anything else, so an
/// install that never opts in never sends a single Apple Event — which is also
/// what keeps macOS's one-time per-app Automation prompt ("Blurt wants to
/// control Spotify" / "…Music", raised by the first event a process sends to
/// that app) away from users who never asked for this.
///
/// Both entry points are fire-and-forget onto a private serial queue: Apple
/// Events are synchronous cross-process IPC into the player, bounded only by
/// the Apple Event timeout, so a hung player must cost one Dispatch thread —
/// never the caller, the main thread, or the cooperative pool (the reasoning on
/// `DictationSession.contextQueue`). Nothing on the press-to-record path ever
/// awaits this type.
public final class MediaPauser: Sendable {
  /// A player app the pauser can control: the name AppleScript commands are
  /// addressed to and the bundle id the process-list read looks for.
  struct Player: Equatable, Sendable {
    let appName: String
    let bundleID: String

    static let spotify = Player(appName: "Spotify", bundleID: "com.spotify.client")
    static let appleMusic = Player(appName: "Music", bundleID: "com.apple.Music")
    /// Every player the production pauser manages, in the order they are
    /// paused and resumed.
    static let all: [Player] = [.spotify, .appleMusic]
  }

  /// What a player reports for `player state`, decoded from the AppleScript
  /// enumeration's text form (see `Client.playerState` in `+Live`). Music can
  /// also report transient states these don't cover (fast forwarding,
  /// rewinding); they decode as nil, which the pauser reads as "don't touch".
  enum PlayerState: String, Sendable {
    case playing, paused, stopped
  }

  /// Which players the last `dictationBegan()` paused — the state the whole
  /// type exists to track: a resume is owed only to the players Blurt paused.
  private let pausedByUs = Mutex([Player]())
  private let client: Client
  private let players: [Player]
  private let isEnabled: @Sendable () -> Bool
  /// Serial, so a dictation's pause always lands before its resume — the host
  /// hands us the phases in order, and this keeps them in order across the hop.
  private let queue = DispatchQueue(
    label: HostIdentity.current.queueLabel("MediaPause"), qos: .userInitiated)

  /// The real player client and the Settings switch — what the app uses.
  public convenience init() {
    self.init(client: .production)
  }

  /// Seam-injected for tests (see `Client`). `isEnabled` defaults to the
  /// Settings switch so `MediaPauseStore.isEnabled` keeps a production
  /// reader; it is a closure so each dictation re-reads the toggle.
  init(
    client: Client,
    players: [Player] = Player.all,
    isEnabled: @escaping @Sendable () -> Bool = { MediaPauseStore().isEnabled }
  ) {
    self.client = client
    self.players = players
    self.isEnabled = isEnabled
  }

  /// Call once per dictation, when the press is accepted. Fire-and-forget:
  /// returns immediately, the player work runs on the pauser's own queue.
  public func dictationBegan() {
    queue.async { self.pauseIfPlaying() }
  }

  /// Call on every terminal phase. Fire-and-forget, and free when nothing is
  /// owed (the owed list is read before any player is so much as looked at),
  /// so hosts can call it for every terminal render — including the initial
  /// `.idle`.
  public func dictationEnded() {
    queue.async { self.resumeIfPaused() }
  }

  /// The decision half of `dictationBegan()`, synchronous for the unit tests.
  /// `isEnabled` is checked before any player is touched, and each player's
  /// `isRunning` (a process-list read, not an Apple Event) before its
  /// `playerState` (which is one) — so the opted-out and the not-running cases
  /// send nothing. A state of paused, stopped, or unreadable (a denied
  /// Automation prompt reads as nil) means nothing to pause for that player,
  /// and nothing owed to it at the end.
  func pauseIfPlaying() {
    // Assigned unconditionally, so every begin discards what the last
    // dictation owed — a stale "we paused it" must never survive into this
    // dictation's end.
    var paused = [Player]()
    if isEnabled() {
      for player in players where client.isRunning(player) && client.playerState(player) == .playing {
        client.pause(player)
        paused.append(player)
      }
    }
    pausedByUs.withLock { $0 = paused }
  }

  /// The decision half of `dictationEnded()`. Resumes only the players the
  /// matching begin paused that are still running; the owed list is consumed
  /// either way, so a resume happens at most once per pause. Deliberately no
  /// second `player state` query: when the user already resumed by hand, `play`
  /// is a no-op, which is simpler than telling that apart from every other
  /// state a player can reach mid-dictation.
  func resumeIfPaused() {
    let owed = pausedByUs.withLock { paused in
      let was = paused
      paused = []
      return was
    }
    for player in owed where client.isRunning(player) {
      client.play(player)
    }
  }
}

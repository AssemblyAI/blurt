import Synchronization
import Testing

@testable import BlurtEngine

/// Exercises the pause/resume decisions through the injected `Client` seam.
/// Every closure is substituted — no test here may touch a real player or
/// send an AppleScript event — and the recorded call log is asserted whole, so
/// "sent no Apple Event at all" is distinguishable from merely "didn't pause".
/// Calls are logged as `call(appName)` since the policy under test is
/// per-player: which of the two players each dictation touched, and in what
/// order.
@Suite("MediaPauser")
struct MediaPauserTests {
  private typealias Player = MediaPauser.Player

  /// The client calls a scenario made, in order.
  private final class ClientLog: Sendable {
    private let calls = Mutex([String]())
    func record(_ call: String, _ player: Player) {
      calls.withLock { $0.append("\(call)(\(player.appName))") }
    }
    var all: [String] { calls.withLock { $0 } }
  }

  /// A pauser over a fully stubbed client, managing the production pair
  /// (Spotify first, then Music). `running` and `state` are closures over the
  /// player so a scenario can differ per player — or have one quit, or its
  /// player state change, between the begin and the end.
  private func makePauser(
    enabled: Bool = true,
    running: @escaping @Sendable (Player) -> Bool = { _ in true },
    state: @escaping @Sendable (Player) -> MediaPauser.PlayerState?,
    log: ClientLog
  ) -> MediaPauser {
    MediaPauser(
      client: MediaPauser.Client(
        isRunning: { player in
          log.record("isRunning", player)
          return running(player)
        },
        playerState: { player in
          log.record("playerState", player)
          return state(player)
        },
        pause: { log.record("pause", $0) },
        play: { log.record("play", $0) }),
      isEnabled: { enabled })
  }

  @Test("pauses every playing player and resumes them at the end")
  func pausesAndResumesBothPlayers() {
    let log = ClientLog()
    let pauser = makePauser(state: { _ in .playing }, log: log)
    pauser.pauseIfPlaying()
    #expect(
      log.all == [
        "isRunning(Spotify)", "playerState(Spotify)", "pause(Spotify)",
        "isRunning(Music)", "playerState(Music)", "pause(Music)",
      ])
    pauser.resumeIfPaused()
    #expect(
      log.all.suffix(4) == ["isRunning(Spotify)", "play(Spotify)", "isRunning(Music)", "play(Music)"])
  }

  @Test("resumes only the player it paused")
  func resumesOnlyThePausedPlayer() {
    let log = ClientLog()
    // Spotify playing, Music sitting paused by the user: only Spotify is owed.
    let pauser = makePauser(state: { $0 == .spotify ? .playing : .paused }, log: log)
    pauser.pauseIfPlaying()
    pauser.resumeIfPaused()
    #expect(
      log.all == [
        "isRunning(Spotify)", "playerState(Spotify)", "pause(Spotify)",
        "isRunning(Music)", "playerState(Music)",
        "isRunning(Spotify)", "play(Spotify)",
      ])
  }

  @Test("disabled sends nothing — not even the state query")
  func disabledSendsNothing() {
    let log = ClientLog()
    let pauser = makePauser(enabled: false, state: { _ in .playing }, log: log)
    pauser.pauseIfPlaying()
    pauser.resumeIfPaused()
    // The whole point of default-off: with the toggle off, players playing or
    // not, the client is never touched, so no Automation prompt can appear.
    #expect(log.all.isEmpty)
  }

  @Test("a player that isn't running is never queried")
  func notRunningNeverQueriesState() {
    let log = ClientLog()
    let pauser = makePauser(running: { _ in false }, state: { _ in .playing }, log: log)
    pauser.pauseIfPlaying()
    pauser.resumeIfPaused()
    // One process-list read per player would be fine too, but nothing owed
    // means the end never even looks: the owed list is consumed before the
    // client.
    #expect(log.all == ["isRunning(Spotify)", "isRunning(Music)"])
  }

  @Test(
    "a player that isn't playing is left alone",
    arguments: [MediaPauser.PlayerState.paused, .stopped, nil])
  func notPlayingIsLeftAlone(state: MediaPauser.PlayerState?) {
    let log = ClientLog()
    let pauser = makePauser(state: { _ in state }, log: log)
    pauser.pauseIfPlaying()
    #expect(
      log.all == [
        "isRunning(Spotify)", "playerState(Spotify)", "isRunning(Music)", "playerState(Music)",
      ])
    pauser.resumeIfPaused()
    // The user paused them (or nothing was playing): Blurt owes no resume.
    #expect(
      log.all == [
        "isRunning(Spotify)", "playerState(Spotify)", "isRunning(Music)", "playerState(Music)",
      ])
  }

  @Test("an end with no matching pause plays nothing")
  func endWithoutPauseIsANoOp() {
    let log = ClientLog()
    let pauser = makePauser(state: { _ in .playing }, log: log)
    pauser.resumeIfPaused()
    #expect(log.all.isEmpty)
  }

  @Test("a pause is resumed at most once")
  func resumesAtMostOnce() {
    let log = ClientLog()
    let pauser = makePauser(state: { $0 == .spotify ? .playing : .stopped }, log: log)
    pauser.pauseIfPlaying()
    pauser.resumeIfPaused()
    let afterFirstResume = log.all
    pauser.resumeIfPaused()
    // The second terminal render (phases keep arriving) finds the owed list
    // already consumed and stops there.
    #expect(log.all == afterFirstResume)
    #expect(log.all.suffix(2) == ["isRunning(Spotify)", "play(Spotify)"])
  }

  @Test("no resume for a player that quit mid-dictation")
  func noResumeAfterPlayerQuits() {
    let log = ClientLog()
    let spotifyStillRunning = Mutex(true)
    let pauser = makePauser(
      running: { player in player == .spotify ? spotifyStillRunning.withLock { $0 } : true },
      state: { _ in .playing }, log: log)
    pauser.pauseIfPlaying()
    spotifyStillRunning.withLock { $0 = false }
    pauser.resumeIfPaused()
    // The end still reads the process list, but sends nothing at a quit app —
    // `play` would relaunch it. Music, still running, is resumed as usual.
    #expect(
      log.all.suffix(3) == ["isRunning(Spotify)", "isRunning(Music)", "play(Music)"])
  }

  @Test("each begin resets what the last dictation owed")
  func beginResetsTheOwedResume() {
    let log = ClientLog()
    let state = Mutex<MediaPauser.PlayerState?>(.playing)
    let pauser = makePauser(state: { _ in state.withLock { $0 } }, log: log)
    pauser.pauseIfPlaying()
    // A second begin that finds both players already paused: the owed list must
    // track the *latest* begin, so the stale "we paused them" from the first is
    // discarded.
    state.withLock { $0 = .paused }
    pauser.pauseIfPlaying()
    pauser.resumeIfPaused()
    #expect(
      log.all.suffix(4) == [
        "isRunning(Spotify)", "playerState(Spotify)", "isRunning(Music)", "playerState(Music)",
      ])
    #expect(!log.all.contains("play(Spotify)"))
    #expect(!log.all.contains("play(Music)"))
  }

  @Test("the public entry points run the same decisions, in order, off the caller")
  func publicEntryPointsRunTheDecisions() async {
    let log = ClientLog()
    let pauser = makePauser(state: { _ in .playing }, log: log)
    pauser.dictationBegan()
    pauser.dictationEnded()
    // Both calls return immediately; the queue is serial and FIFO, so once the
    // resume's last `play` lands, both decisions have run in order. Bounded
    // poll rather than a bare spin, so a regression fails instead of hanging.
    for _ in 0..<2_000 where log.all.last != "play(Music)" {
      try? await Task.sleep(for: .milliseconds(1))
    }
    #expect(
      log.all == [
        "isRunning(Spotify)", "playerState(Spotify)", "pause(Spotify)",
        "isRunning(Music)", "playerState(Music)", "pause(Music)",
        "isRunning(Spotify)", "play(Spotify)", "isRunning(Music)", "play(Music)",
      ])
  }
}

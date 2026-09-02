import Synchronization
import Testing

@testable import BlurtEngine

/// Exercises the pause/resume decisions through the injected `Client` seam.
/// Every closure is substituted — no test here may touch the real Spotify or
/// send an AppleScript event — and the recorded call log is asserted whole, so
/// "sent no Apple Event at all" is distinguishable from merely "didn't pause".
@Suite("SpotifyPauser")
struct SpotifyPauserTests {
  /// The client calls a scenario made, in order.
  private final class ClientLog: Sendable {
    private let calls = Mutex([String]())
    func record(_ call: String) { calls.withLock { $0.append(call) } }
    var all: [String] { calls.withLock { $0 } }
  }

  /// A pauser over a fully stubbed client. `running` and `state` are closures
  /// so a scenario can have Spotify quit — or its player state change —
  /// between the begin and the end.
  private func makePauser(
    enabled: Bool,
    running: @escaping @Sendable () -> Bool,
    state: @escaping @Sendable () -> SpotifyPauser.PlayerState?,
    log: ClientLog
  ) -> SpotifyPauser {
    SpotifyPauser(
      client: SpotifyPauser.Client(
        isRunning: {
          log.record("isRunning")
          return running()
        },
        playerState: {
          log.record("playerState")
          return state()
        },
        pause: { log.record("pause") },
        play: { log.record("play") }),
      isEnabled: { enabled })
  }

  @Test("pauses a playing Spotify and resumes it at the end")
  func pausesAndResumes() {
    let log = ClientLog()
    let pauser = makePauser(enabled: true, running: { true }, state: { .playing }, log: log)
    pauser.pauseIfPlaying()
    #expect(log.all == ["isRunning", "playerState", "pause"])
    pauser.resumeIfPaused()
    #expect(log.all == ["isRunning", "playerState", "pause", "isRunning", "play"])
  }

  @Test("disabled sends nothing — not even the state query")
  func disabledSendsNothing() {
    let log = ClientLog()
    let pauser = makePauser(enabled: false, running: { true }, state: { .playing }, log: log)
    pauser.pauseIfPlaying()
    pauser.resumeIfPaused()
    // The whole point of default-off: with the toggle off, Spotify playing or
    // not, the client is never touched, so no Automation prompt can appear.
    #expect(log.all.isEmpty)
  }

  @Test("a Spotify that isn't running is never queried")
  func notRunningNeverQueriesState() {
    let log = ClientLog()
    let pauser = makePauser(enabled: true, running: { false }, state: { .playing }, log: log)
    pauser.pauseIfPlaying()
    pauser.resumeIfPaused()
    // One process-list read per call site would be fine too, but nothing owed
    // means the end never even looks: the flag is consumed before the client.
    #expect(log.all == ["isRunning"])
  }

  @Test(
    "a Spotify that isn't playing is left alone",
    arguments: [SpotifyPauser.PlayerState.paused, .stopped, nil])
  func notPlayingIsLeftAlone(state: SpotifyPauser.PlayerState?) {
    let log = ClientLog()
    let pauser = makePauser(enabled: true, running: { true }, state: { state }, log: log)
    pauser.pauseIfPlaying()
    #expect(log.all == ["isRunning", "playerState"])
    pauser.resumeIfPaused()
    // The user paused it (or nothing was playing): Blurt owes no resume.
    #expect(log.all == ["isRunning", "playerState"])
  }

  @Test("an end with no matching pause plays nothing")
  func endWithoutPauseIsANoOp() {
    let log = ClientLog()
    let pauser = makePauser(enabled: true, running: { true }, state: { .playing }, log: log)
    pauser.resumeIfPaused()
    #expect(log.all.isEmpty)
  }

  @Test("a pause is resumed at most once")
  func resumesAtMostOnce() {
    let log = ClientLog()
    let pauser = makePauser(enabled: true, running: { true }, state: { .playing }, log: log)
    pauser.pauseIfPlaying()
    pauser.resumeIfPaused()
    pauser.resumeIfPaused()
    // The second terminal render (phases keep arriving) finds the flag already
    // consumed and stops there.
    #expect(log.all == ["isRunning", "playerState", "pause", "isRunning", "play"])
  }

  @Test("no resume when Spotify quit mid-dictation")
  func noResumeAfterSpotifyQuit() {
    let log = ClientLog()
    let stillRunning = Mutex(true)
    let pauser = makePauser(
      enabled: true, running: { stillRunning.withLock { $0 } }, state: { .playing }, log: log)
    pauser.pauseIfPlaying()
    stillRunning.withLock { $0 = false }
    pauser.resumeIfPaused()
    // The end still reads the process list, but sends nothing at a quit app —
    // `play` would relaunch it.
    #expect(log.all == ["isRunning", "playerState", "pause", "isRunning"])
  }

  @Test("each begin resets what the last dictation owed")
  func beginResetsTheOwedResume() {
    let log = ClientLog()
    let state = Mutex<SpotifyPauser.PlayerState?>(.playing)
    let pauser = makePauser(
      enabled: true, running: { true }, state: { state.withLock { $0 } }, log: log)
    pauser.pauseIfPlaying()
    // A second begin that finds Spotify already paused: the flag must track the
    // *latest* begin, so the stale "we paused it" from the first is discarded.
    state.withLock { $0 = .paused }
    pauser.pauseIfPlaying()
    pauser.resumeIfPaused()
    #expect(log.all == ["isRunning", "playerState", "pause", "isRunning", "playerState"])
  }

  @Test("the public entry points run the same decisions, in order, off the caller")
  func publicEntryPointsRunTheDecisions() async {
    let log = ClientLog()
    let pauser = makePauser(enabled: true, running: { true }, state: { .playing }, log: log)
    pauser.dictationBegan()
    pauser.dictationEnded()
    // Both calls return immediately; the queue is serial and FIFO, so once the
    // resume's `play` lands, both decisions have run in order. Bounded poll
    // rather than a bare spin, so a regression fails instead of hanging.
    for _ in 0..<2_000 where log.all.last != "play" {
      try? await Task.sleep(for: .milliseconds(1))
    }
    #expect(log.all == ["isRunning", "playerState", "pause", "isRunning", "play"])
  }
}

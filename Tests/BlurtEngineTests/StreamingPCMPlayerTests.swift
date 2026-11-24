import Foundation
import Synchronization
import Testing

@testable import BlurtEngine

/// The PCM player's bookkeeping, around real playback of silence: what it
/// reports queued and loud, how stopping and a bad rate are handled, and that a
/// drain always finishes. (The drain's bound — queued audio over the rate, plus
/// slack — is what keeps a read from sticking on "reading" when no output
/// device moves the clock; a frozen clock can't be staged here, so these check
/// the bound holds with one.)
///
/// The drain's deadline runs on a `TestClock`, so the bound is checked in
/// virtual time rather than timed: timing it on the wall needed a margin a
/// loaded CI runner kept outgrowing (it overshot one by 0.1 s, at 2.85 s).
@Suite("StreamingPCMPlayer", .timeLimit(.minutes(1)))
struct StreamingPCMPlayerTests {
  /// `seconds` of silence at the TTS sample rate.
  private func silence(seconds: Double) -> Data {
    Data(count: Int(Double(AssemblyAISpeechSynthesizer.sampleRate) * seconds) * 2)
  }

  /// Drains `player`, waking each of its polls on `clock` as it parks, and
  /// answers how much virtual time the drain took. The media clock still runs
  /// on the wall, so whether the drain ends on its deadline or because the
  /// audio played out first depends on the machine; how long it may take in
  /// virtual time does not.
  private func drain(_ player: StreamingPCMPlayer, on clock: TestClock) async -> Duration {
    let finished = Finished()
    let draining = Task {
      await player.drain()
      finished.set()
    }
    while !finished.value {
      if let next = clock.sleepingFor.first {
        clock.advance(by: next)
      } else {
        await Task.yield()
      }
    }
    await draining.value
    return clock.now.offset
  }

  /// The longest a drain of `seconds` of audio at `rate` may take: the audio
  /// at that rate, the schedule's start lead, the slack, and the one poll that
  /// can straddle the deadline.
  private func bound(seconds: Double, rate: Double) -> Duration {
    .seconds(seconds / rate + PCMSchedule.lead) + StreamingPCMPlayer.drainSlack
      + StreamingPCMPlayer.drainPollCeiling
  }

  @Test("a zero, negative or non-finite rate plays at 1 rather than trapping the drain")
  func badRateFallsBack() async {
    for rate in [0, -1, .nan, .infinity] {
      let clock = TestClock()
      let player = StreamingPCMPlayer(sampleRate: AssemblyAISpeechSynthesizer.sampleRate, rate: rate, clock: clock)
      player.enqueue(silence(seconds: 0.05))
      // Bounded as a rate of 1 bounds it: the fallback rate is what the
      // deadline divides by.
      #expect(await drain(player, on: clock) <= bound(seconds: 0.05, rate: 1), "rate \(rate)")
    }
  }

  @Test("a drain finishes within the audio queued plus its slack")
  func drainIsBounded() async {
    let clock = TestClock()
    let player = StreamingPCMPlayer(sampleRate: AssemblyAISpeechSynthesizer.sampleRate, rate: 2, clock: clock)
    player.enqueue(silence(seconds: 0.5))
    // With no output device the media clock never moves, so the drain waits
    // out its whole deadline — the queued audio at 2× plus its slack — and its
    // last poll can carry it at most one poll past.
    #expect(await drain(player, on: clock) <= bound(seconds: 0.5, rate: 2))
    #expect(player.bufferedSeconds == 0)
  }

  @Test("queued audio is reported in listening time, and nothing once stopped")
  func bufferedSeconds() {
    let player = StreamingPCMPlayer(sampleRate: AssemblyAISpeechSynthesizer.sampleRate, rate: 2)
    #expect(player.bufferedSeconds == 0)
    player.enqueue(silence(seconds: 1))
    // A second of audio at 2× is half a second of listening, plus the
    // schedule's start lead.
    #expect(player.bufferedSeconds > 0.3 && player.bufferedSeconds <= 0.5 + PCMSchedule.lead)
    player.stop()
    #expect(player.bufferedSeconds == 0)
    #expect(player.currentLevel == 0)
  }

  @Test("stopping twice is safe, audio after a stop is ignored, and so is less than a sample")
  func stopAndShortInput() async {
    let clock = TestClock()
    let player = StreamingPCMPlayer(sampleRate: AssemblyAISpeechSynthesizer.sampleRate, clock: clock)
    player.enqueue(Data())
    player.enqueue(Data([1]))
    #expect(player.bufferedSeconds == 0)
    player.stop()
    player.stop()
    player.enqueue(silence(seconds: 1))
    #expect(player.bufferedSeconds == 0)
    // Nothing left to wait for: the drain returns without a single poll.
    #expect(await drain(player, on: clock) == .zero)
  }

  @Test("silence reads as no level")
  func silenceHasNoLevel() {
    let player = StreamingPCMPlayer(sampleRate: AssemblyAISpeechSynthesizer.sampleRate)
    player.enqueue(silence(seconds: 0.5))
    #expect(player.currentLevel == 0)
    player.stop()
  }
}

/// Set once a drain under test has returned, read by the loop stepping its clock.
private final class Finished: Sendable {
  private let state = Mutex(false)
  var value: Bool { state.withLock { $0 } }
  func set() { state.withLock { $0 = true } }
}

import Foundation
import Testing

@testable import BlurtEngine

/// The PCM player's bookkeeping, around real playback of silence: what it
/// reports queued and loud, how stopping and a bad rate are handled, and that a
/// drain always finishes. (The drain's bound — queued audio over the rate, plus
/// slack — is what keeps a read from sticking on "reading" when no output
/// device moves the clock; a frozen clock can't be staged here, so these check
/// the bound holds with one.)
@Suite("StreamingPCMPlayer", .timeLimit(.minutes(1)))
struct StreamingPCMPlayerTests {
  /// `seconds` of silence at the TTS sample rate.
  private func silence(seconds: Double) -> Data {
    Data(count: Int(Double(AssemblyAISpeechSynthesizer.sampleRate) * seconds) * 2)
  }

  @Test("a zero, negative or non-finite rate plays at 1 rather than trapping the drain")
  func badRateFallsBack() async {
    for rate in [0, -1, .nan, .infinity] {
      let player = StreamingPCMPlayer(sampleRate: AssemblyAISpeechSynthesizer.sampleRate, rate: rate)
      player.enqueue(silence(seconds: 0.05))
      let start = ContinuousClock.now
      await player.drain()
      #expect(ContinuousClock.now - start < .seconds(3), "rate \(rate)")
    }
  }

  @Test("a drain finishes within the audio queued plus its slack")
  func drainIsBounded() async {
    let player = StreamingPCMPlayer(sampleRate: AssemblyAISpeechSynthesizer.sampleRate, rate: 2)
    player.enqueue(silence(seconds: 0.5))
    let start = ContinuousClock.now
    await player.drain()
    #expect(ContinuousClock.now - start < .seconds(0.25 + 2 + 0.5))
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
    let player = StreamingPCMPlayer(sampleRate: AssemblyAISpeechSynthesizer.sampleRate)
    player.enqueue(Data())
    player.enqueue(Data([1]))
    #expect(player.bufferedSeconds == 0)
    player.stop()
    player.stop()
    player.enqueue(silence(seconds: 1))
    #expect(player.bufferedSeconds == 0)
    let start = ContinuousClock.now
    await player.drain()
    #expect(ContinuousClock.now - start < .seconds(1))
  }

  @Test("silence reads as no level")
  func silenceHasNoLevel() {
    let player = StreamingPCMPlayer(sampleRate: AssemblyAISpeechSynthesizer.sampleRate)
    player.enqueue(silence(seconds: 0.5))
    #expect(player.currentLevel == 0)
    player.stop()
  }
}

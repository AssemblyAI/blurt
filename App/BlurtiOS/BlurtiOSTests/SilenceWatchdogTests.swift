import AVFoundation
import Foundation
import Synchronization
import Testing

@testable import BlurtiOS

@Suite("Silence watchdog")
struct SilenceWatchdogTests {
  /// How many times the feed said silent.
  nonisolated private final class Silences: Sendable {
    private let count = Mutex(0)

    var value: Int { count.withLock { $0 } }

    func bump() { count.withLock { $0 += 1 } }
  }

  /// A chunk with sound in it.
  private static let live = [Int16](repeating: 1_000, count: 1_600).withUnsafeBufferPointer { Data(buffer: $0) }

  /// `seconds` of digital silence, as 16 kHz mono 16-bit PCM.
  private static func zeros(seconds: Double) -> Data {
    Data(count: Int(seconds * Double(UtteranceFeed.silenceBytes)))
  }

  private static func feed() -> (UtteranceFeed, Silences) {
    let silences = Silences()
    return (UtteranceFeed { silences.bump() }, silences)
  }

  @Test("the second is a second of 16 kHz mono 16-bit; a start's grace is the parked bring-up's budget")
  func constant() {
    #expect(UtteranceFeed.silenceSeconds == 1)
    #expect(UtteranceFeed.silenceBytes == 32_000)
    #expect(UtteranceFeed.startGraceSeconds == 3)
    #expect(UtteranceFeed.startGraceBytes == 96_000)
  }

  @Test("a second of zeros in an open utterance says silent, once per run; a live chunk starts the count over")
  func silent() {
    let (feed, count) = Self.feed()
    feed.deliver(Self.zeros(seconds: 2))
    #expect(count.value == 0, "nothing between utterances")
    _ = feed.begin()
    feed.deliver(Self.live)
    for _ in 0..<9 { feed.deliver(Self.zeros(seconds: 0.1)) }
    #expect(count.value == 0, "0.9 s is not a second")
    feed.deliver(Self.zeros(seconds: 0.1))
    #expect(count.value == 1)
    feed.deliver(Self.zeros(seconds: 3))
    #expect(count.value == 1, "said once per run")
    feed.deliver(Self.live)
    feed.deliver(Self.zeros(seconds: 0.5))
    #expect(count.value == 1, "the live chunk started the count over")
    feed.deliver(Self.zeros(seconds: 0.5))
    #expect(count.value == 2)
    feed.end()
    feed.deliver(Self.zeros(seconds: 2))
    #expect(count.value == 2, "nothing after the utterance")
    _ = feed.begin()
    feed.deliver(Self.live)
    feed.deliver(Self.zeros(seconds: 1))
    #expect(count.value == 3, "the next utterance counts afresh")
    feed.end()
  }

  @Test("the zeros still reach the utterance and its tally")
  func delivered() async {
    let (feed, _) = Self.feed()
    let stream = feed.begin()
    feed.deliver(Self.zeros(seconds: 1))
    #expect(feed.bytesSoFar == UtteranceFeed.silenceBytes)
    #expect(feed.end() == UtteranceFeed.silenceBytes)
    var received = 0
    for await chunk in stream { received += chunk.count }
    #expect(received == UtteranceFeed.silenceBytes)
  }

  @Test("a start or a route change holds the watchdog until a live chunk; only zeros are said after the grace")
  func startHoldsWatchdog() {
    let (feed, count) = Self.feed()
    _ = feed.begin()
    feed.deliver(Self.zeros(seconds: 2.5))
    #expect(count.value == 0, "a route coming up delivers zeros, held or parked")
    feed.deliver(Self.live)
    feed.deliver(Self.zeros(seconds: 1))
    #expect(count.value == 1, "a second of zeros once the route is live")
    feed.holdSilence()
    feed.deliver(Self.zeros(seconds: 2.5))
    #expect(count.value == 1, "the new route is coming up")
    feed.deliver(Self.zeros(seconds: 0.5))
    #expect(count.value == 2, "a route that never comes up is said after the grace")
    feed.end()
    _ = feed.begin()
    feed.deliver(Self.zeros(seconds: 3))
    #expect(count.value == 3, "a mic that only ever delivers zeros is said, not recorded")
    feed.end()
  }
}

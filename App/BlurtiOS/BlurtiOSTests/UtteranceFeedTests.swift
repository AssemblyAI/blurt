import Foundation
import Testing

@testable import BlurtiOS

@Suite("Utterance feed")
struct UtteranceFeedTests {
  private func pcm(_ samples: [Int16]) -> Data {
    samples.withUnsafeBufferPointer { Data(buffer: $0) }
  }

  @Test("digital silence is all zeros; a quiet room's noise floor is not")
  func digitalSilence() {
    #expect(UtteranceFeed.isDigitalSilence(pcm([0, 0, 0, 0])))
    #expect(!UtteranceFeed.isDigitalSilence(pcm([0, 1, 0, 0])))
    #expect(!UtteranceFeed.isDigitalSilence(pcm([3, -3, 2, -2])))
  }

  @Test("chunks reach the utterance between begin and end, the tally counts them, and nothing outside")
  func tally() async {
    let feed = UtteranceFeed()
    feed.deliver(pcm([1_000, -1_000]))
    #expect(!feed.isCapturing)
    let stream = feed.begin()
    #expect(feed.isCapturing)
    feed.deliver(pcm([1_000, -1_000]))
    feed.deliver(pcm([1_000, -1_000, 1_000]))
    let bytes = feed.end()
    #expect(bytes == 10)
    #expect(!feed.isCapturing)
    var received = 0
    for await chunk in stream { received += chunk.count }
    #expect(received == 10)
    feed.deliver(pcm([1]))
    #expect(feed.end() == 0)
  }
}

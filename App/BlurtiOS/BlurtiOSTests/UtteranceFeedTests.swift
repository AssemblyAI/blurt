import Foundation
import Testing

@testable import BlurtiOS

@Suite("Utterance feed")
struct UtteranceFeedTests {
  private func pcm(_ samples: [Int16]) -> Data {
    samples.withUnsafeBufferPointer { Data(buffer: $0) }
  }

  @Test("level: silence is 0, full scale is 1, room ambient under the floor is 0")
  func level() {
    #expect(UtteranceFeed.level(of: pcm([0, 0, 0, 0])) == 0)
    #expect(UtteranceFeed.level(of: pcm([Int16.max, Int16.max, -Int16.max, -Int16.max])) == 1)
    #expect(UtteranceFeed.level(of: pcm([3, -3, 2, -2])) == 0)
    #expect(UtteranceFeed.level(of: Data()) == 0)
    let mid = UtteranceFeed.level(of: pcm([8000, -8000, 8000, -8000]))
    #expect(mid > 0 && mid < 1)
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
    feed.deliver(pcm([1000, -1000]))
    #expect(!feed.isCapturing)
    let stream = feed.begin()
    #expect(feed.isCapturing)
    feed.deliver(pcm([1000, -1000]))
    feed.deliver(pcm([1000, -1000, 1000]))
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

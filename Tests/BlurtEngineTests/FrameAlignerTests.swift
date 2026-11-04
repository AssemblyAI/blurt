import Foundation
import Testing

@testable import AssemblyAI
@testable import BlurtEngine

@Suite("FrameAligner")
struct FrameAlignerTests {
  @Test("whole-sample chunks pass through untouched")
  func evenChunks() {
    var aligner = FrameAligner()
    #expect(aligner.align(Data([1, 2, 3, 4])) == Data([1, 2, 3, 4]))
    #expect(!aligner.sawMisalignedChunk)
    #expect(!aligner.hasDanglingByte)
  }

  @Test("an odd chunk's last byte is held for the next, so every chunk sent is whole samples")
  func oddChunks() {
    var aligner = FrameAligner()
    let first = aligner.align(Data([1, 2, 3]))
    let second = aligner.align(Data([4, 5, 6, 7, 8]))
    #expect(first == Data([1, 2]))
    #expect(second == Data([3, 4, 5, 6, 7, 8]))
    #expect(aligner.sawMisalignedChunk)
    #expect(!aligner.hasDanglingByte)
    // Nothing lost or reordered.
    #expect(first + second == Data([1, 2, 3, 4, 5, 6, 7, 8]))
  }

  @Test("a recording that ends odd drops only its last half sample, and a lone byte waits")
  func danglingByte() {
    var aligner = FrameAligner()
    #expect(aligner.align(Data([9])).isEmpty)
    #expect(aligner.hasDanglingByte)
    #expect(aligner.align(Data([1, 2])) == Data([9, 1]))
    #expect(aligner.hasDanglingByte)
  }

  @Test("the relay hands the upload and its fallback copy whole samples, even from odd capture buffers")
  func relayAligns() async {
    let (frames, feed) = AsyncStream<Data>.makeStream()
    let (live, sink) = AsyncStream<Data>.makeStream()
    feed.yield(Data([1, 2, 3]))
    feed.yield(Data([4, 5, 6, 7, 8]))
    feed.yield(Data([9]))
    feed.finish()
    let copy = await AssemblyAITranscriber.relay(frames, to: sink, keepingAtMost: 1_000)
    var sent = Data()
    for await chunk in live {
      #expect(chunk.count.isMultiple(of: 2))
      sent += chunk
    }
    #expect(sent == Data([1, 2, 3, 4, 5, 6, 7, 8]))
    #expect(copy == sent)
  }
}

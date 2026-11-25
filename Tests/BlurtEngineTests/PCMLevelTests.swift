import Foundation
import Testing

@testable import BlurtEngine

@Suite("PCMLevel")
struct PCMLevelTests {
  private func pcm(_ samples: [Int16]) -> Data {
    unsafe samples.withUnsafeBufferPointer { unsafe Data(buffer: $0) }
  }

  @Test("silence reads 0, full scale reads 1, and a quieter voice reads in between")
  func scale() throws {
    #expect(PCMLevel.levels(of: pcm(Array(repeating: 0, count: 100)), windowFrames: 100) == [0])
    #expect(PCMLevel.levels(of: pcm(Array(repeating: .max, count: 100)), windowFrames: 100) == [1])
    let quiet = try #require(PCMLevel.levels(of: pcm(Array(repeating: 1_000, count: 100)), windowFrames: 100).first)
    #expect(quiet > 0 && quiet < 1)
  }

  @Test("level(of:) reads a whole chunk: silence and room ambient are 0, full scale is 1")
  func wholeChunk() {
    #expect(PCMLevel.level(of: pcm([0, 0, 0, 0])) == 0)
    #expect(PCMLevel.level(of: pcm([Int16.max, Int16.max, -Int16.max, -Int16.max])) == 1)
    #expect(PCMLevel.level(of: pcm([3, -3, 2, -2])) == 0)
    #expect(PCMLevel.level(of: Data()) == 0)
    #expect(PCMLevel.level(of: Data([0x7F])) == 0)
    let mid = PCMLevel.level(of: pcm([8_000, -8_000, 8_000, -8_000]))
    #expect(mid > 0 && mid < 1)
  }

  @Test("one level per window, the last one short, an odd byte ignored")
  func windows() {
    var data = pcm(Array(repeating: 0, count: 50) + Array(repeating: .max, count: 25))
    data.append(0x7F)
    #expect(PCMLevel.levels(of: data, windowFrames: 50) == [0, 1])
    #expect(PCMLevel.levels(of: Data(), windowFrames: 50).isEmpty)
    #expect(PCMLevel.levels(of: data, windowFrames: 0).isEmpty)
  }

  @Test("samples that don't start on a 2-byte boundary read the same as aligned ones")
  func unalignedSamples() {
    let aligned = pcm(Array(repeating: 0, count: 50) + Array(repeating: .max, count: 50))
    // One byte in, as a chunk with a carried byte prepended or a URLSession
    // block can be: the slice's storage is off the `Int16` alignment.
    var padded = Data([0xAA])
    padded.append(aligned)
    let unaligned = padded.dropFirst()
    #expect(PCMLevel.levels(of: unaligned, windowFrames: 50) == [0, 1])
  }

  @Test("a read wears its own pill state, steady and announced")
  func speakingPill() {
    #expect(OverlayUIState.speaking.accessibilityLabel == "Reading aloud.")
    #expect(OverlayUIState.speaking.noticeDwellSeconds == nil)
  }
}

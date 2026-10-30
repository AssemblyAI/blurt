import Foundation
import Testing

@testable import BlurtEngine

@Suite("PCMLevel")
struct PCMLevelTests {
  private func pcm(_ samples: [Int16]) -> Data {
    samples.withUnsafeBufferPointer { Data(buffer: $0) }
  }

  @Test("silence reads 0, full scale reads 1, and a quieter voice reads in between")
  func scale() throws {
    #expect(PCMLevel.levels(of: pcm(Array(repeating: 0, count: 100)), windowFrames: 100) == [0])
    #expect(PCMLevel.levels(of: pcm(Array(repeating: .max, count: 100)), windowFrames: 100) == [1])
    let quiet = try #require(PCMLevel.levels(of: pcm(Array(repeating: 1_000, count: 100)), windowFrames: 100).first)
    #expect(quiet > 0 && quiet < 1)
  }

  @Test("one level per window, the last one short, an odd byte ignored")
  func windows() {
    var data = pcm(Array(repeating: 0, count: 50) + Array(repeating: .max, count: 25))
    data.append(0x7F)
    #expect(PCMLevel.levels(of: data, windowFrames: 50) == [0, 1])
    #expect(PCMLevel.levels(of: Data(), windowFrames: 50).isEmpty)
    #expect(PCMLevel.levels(of: data, windowFrames: 0).isEmpty)
  }

  @Test("a read wears its own pill state, steady and announced")
  func speakingPill() {
    #expect(OverlayUIState.speaking.accessibilityLabel == "Reading aloud.")
    #expect(OverlayUIState.speaking.noticeDwellSeconds == nil)
  }

  @Test("while a read plays, only a new capture takes the pill; otherwise the phase does")
  func pillWhileSpeaking() {
    #expect(PipelinePhase.idle.overlayState(whileSpeaking: true) == nil)
    #expect(PipelinePhase.pasted.overlayState(whileSpeaking: true) == nil)
    #expect(PipelinePhase.recording.overlayState(whileSpeaking: true) == .recording)
    #expect(PipelinePhase.idle.overlayState(whileSpeaking: false) == .idle)
    #expect(PipelinePhase.pasted.overlayState(whileSpeaking: false) == .pasted)
  }
}

import Foundation
import Testing

@testable import BlurtEngine

@Suite("PCMEncoder")
struct PCMEncoderTests {
  @Test("emits headerless 16-bit little-endian samples")
  func sizeAndLayout() {
    let samples: [Float] = [0, 0.5, -0.5]
    let data = PCMEncoder.encodeS16LE(samples: samples)

    // No container: exactly two bytes per sample, no RIFF/WAVE header.
    #expect(data.count == samples.count * 2)
    #expect(readInt16LE(data, 0) == 0)
  }

  @Test("clamps and scales float samples to Int16 range")
  func sampleScaling() {
    let samples: [Float] = [0, 1.0, -1.0, 2.0]  // 2.0 should clamp to +full-scale
    let data = PCMEncoder.encodeS16LE(samples: samples)

    // Symmetric ×32767 scaling: full-scale negative is -32767, not -32768.
    #expect(readInt16LE(data, 0) == 0)
    #expect(readInt16LE(data, 2) == 32_767)
    #expect(readInt16LE(data, 4) == -32_767)
    #expect(readInt16LE(data, 6) == 32_767)
  }

  // MARK: - helpers

  private func readInt16LE(_ data: Data, _ offset: Int) -> Int16 {
    Int16(bitPattern: UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8))
  }
}

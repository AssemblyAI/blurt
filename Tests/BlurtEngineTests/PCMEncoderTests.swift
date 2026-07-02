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

  @Test("empty input encodes to empty data")
  func emptyInput() {
    #expect(PCMEncoder.encodeS16LE(samples: []).isEmpty)
  }

  @Test("clip is symmetric: below −1 clamps to −full-scale")
  func negativeClip() {
    let data = PCMEncoder.encodeS16LE(samples: [-2.0])
    #expect(readInt16LE(data, 0) == -32_767)
  }

  @Test("out-of-range non-finite samples clamp to full scale instead of wrapping")
  func infiniteSamplesClamp() {
    // A corrupt capture buffer must never wrap around into garbage audio; the
    // clip stage pins ±∞ to the same full-scale values as any out-of-range float.
    let data = PCMEncoder.encodeS16LE(samples: [.infinity, -.infinity])
    #expect(readInt16LE(data, 0) == 32_767)
    #expect(readInt16LE(data, 2) == -32_767)
  }

  @Test("conversion rounds to nearest rather than truncating")
  func roundsToNearest() {
    // 0.5 × 32767 = 16383.5 → 16384 when rounded (vDSP_vfixr16); truncation
    // (vDSP_vfix16) would yield 16383. Pins the documented rounding choice.
    let data = PCMEncoder.encodeS16LE(samples: [0.5, -0.5])
    #expect(readInt16LE(data, 0) == 16_384)
    #expect(readInt16LE(data, 2) == -16_384)
  }

  // MARK: - helpers

  private func readInt16LE(_ data: Data, _ offset: Int) -> Int16 {
    Int16(bitPattern: UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8))
  }
}

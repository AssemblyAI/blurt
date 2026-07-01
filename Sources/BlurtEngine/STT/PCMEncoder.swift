import Accelerate
import Foundation

/// Encodes mono Float32 PCM samples into raw little-endian 16-bit PCM (S16LE).
///
/// AssemblyAI's Sync STT API (`POST sync.assemblyai.com/transcribe`) takes the
/// audio as a headerless PCM blob plus a JSON `config` describing its geometry
/// (`sample_rate`, `channels`), so no WAV/RIFF container is needed. Samples are
/// expected in the range [-1, 1]; anything outside is clipped below.
enum PCMEncoder {
  static func encodeS16LE(samples: [Float]) -> Data {
    guard !samples.isEmpty else { return Data() }
    // Clip to [-1, 1], scale to full-scale, and convert Float→Int16 (rounding)
    // in a few SIMD passes via Accelerate, rather than a per-sample loop.
    // Symmetric ×32767 scaling: -1.0 → -32767 and +1.0 → +32767, the standard
    // encoder convention.
    var scaled = [Float](repeating: 0, count: samples.count)
    vDSP.clip(samples, to: -1.0...1.0, result: &scaled)
    var gain: Float = 32_767
    vDSP_vsmul(scaled, 1, &gain, &scaled, 1, vDSP_Length(scaled.count))
    var out = [Int16](repeating: 0, count: scaled.count)
    // vDSP_vfixr16 rounds to nearest; vDSP_vfix16 would truncate toward zero.
    vDSP_vfixr16(scaled, 1, &out, 1, vDSP_Length(out.count))
    // Int16 stores host-endian; Apple platforms (arm64/x86_64) are little-endian,
    // so this buffer is already the S16LE the Sync API expects.
    return out.withUnsafeBytes { Data($0) }
  }
}

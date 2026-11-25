public import Foundation

/// The loudness of PCM16 LE mono audio on the mic meter's 0...1 scale
/// (`MicCapture.linearLevel`), so the pill's meter reads a voice playing back
/// the way it reads one being recorded, and a host that captures its own PCM
/// (the iPhone's listening window) meters it on the Mac's scale.
public enum PCMLevel {
  // periphery:ignore - public for the iOS app (App/BlurtiOS), which the Mac scan doesn't index.
  /// The level of the whole of `pcm`: 0 for silence, for room ambient under
  /// the meter's floor and for no audio at all; 1 at full scale.
  public static func level(of pcm: Data) -> Float {
    levels(of: pcm, windowFrames: max(1, pcm.count / 2)).first ?? 0
  }

  /// One level per `windowFrames`-frame window of `pcm`, the last window
  /// possibly short. An odd trailing byte is ignored. Samples are loaded
  /// unaligned: URLSession's blocks, a chunk with a carried byte prepended, and
  /// a `Data` slice needn't start on an `Int16` boundary.
  static func levels(of pcm: Data, windowFrames: Int) -> [Float] {
    let frames = pcm.count / 2
    guard frames > 0, windowFrames > 0 else {
      return []
    }
    return unsafe pcm.withUnsafeBytes { raw in
      stride(from: 0, to: frames, by: windowFrames).map { start in
        let end = min(start + windowFrames, frames)
        var sum: Double = 0
        for index in start..<end {
          let bits = unsafe raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self)
          let sample = Double(Int16(littleEndian: bits)) / Double(Int16.max)
          sum += sample * sample
        }
        let rms = (sum / Double(end - start)).squareRoot()
        return MicCapture.linearLevel(fromPowerDB: Float(20 * log10(rms)))
      }
    }
  }
}

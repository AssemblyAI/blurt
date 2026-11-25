import Foundation

/// The loudness of PCM16 LE mono audio on the mic meter's 0...1 scale
/// (`MicCapture.linearLevel`), so the pill's meter reads a voice playing back
/// the way it reads one being recorded.
enum PCMLevel {
  /// One level per `windowFrames`-frame window of `pcm`, the last window
  /// possibly short. An odd trailing byte is ignored. Samples are loaded
  /// unaligned: URLSession's blocks, and a chunk with a carried byte prepended,
  /// needn't start on an `Int16` boundary.
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

import Foundation

/// Keeps a stream of 16-bit PCM chunks on whole samples, whatever sizes the
/// chunks arrive in.
///
/// The dictation route reads its `audio` part two bytes at a time, and a body
/// whose audio ends on half a sample is refused outright — `400 stream ended
/// mid-frame with 1 trailing byte(s)` (seen 2026-11-03, from Slack dictations).
/// The capture asks for 16-bit mono, so every buffer should already be a whole
/// number of samples; when one isn't, every byte after it is off the two-byte
/// grid and the whole recording is lost. This carries an odd buffer's last byte
/// over to the front of the next one, so what's uploaded is always whole
/// samples, and only the very last byte of a recording that ends odd is dropped.
public struct FrameAligner: Sendable {
  /// Bytes in one sample: 16-bit mono.
  public static let bytesPerFrame = 2

  /// The byte held back from the last chunk, waiting for its pair.
  private var carry: Data = Data()
  /// Whether any chunk so far was off the grid: worth one log line, since it
  /// names an input device that isn't honouring the capture's format.
  public private(set) var sawMisalignedChunk = false

  public init() {}

  /// `chunk` with the held-back byte in front of it, trimmed to whole samples;
  /// what doesn't fit is held back for the next one.
  public mutating func align(_ chunk: Data) -> Data {
    if !chunk.count.isMultiple(of: Self.bytesPerFrame) { sawMisalignedChunk = true }
    let joined = carry + chunk
    let whole = joined.count - joined.count % Self.bytesPerFrame
    carry = joined.suffix(from: joined.startIndex + whole)
    return joined.prefix(whole)
  }

  /// Whether a byte is still held back when the recording ends: half a sample,
  /// which is dropped rather than sent.
  public var hasDanglingByte: Bool { !carry.isEmpty }
}

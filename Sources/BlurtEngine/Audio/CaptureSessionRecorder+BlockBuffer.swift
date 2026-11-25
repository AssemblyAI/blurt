import CoreMedia
import Foundation

// The delivery path's one copy out of a sample buffer, split out of
// `CaptureSessionRecorder.swift` to stay within the lint file-length budget.
extension CaptureSessionRecorder {
  /// The block buffer's `length` bytes, copied exactly **once** — this runs on
  /// the audio delivery queue, which this file goes to lengths elsewhere to keep
  /// unblocked.
  ///
  /// Prefers the buffer's own pointer, which needs no destination allocation and
  /// so no zero-fill. `Data(count:)` is documented to hand back *zeroed* bytes,
  /// so the fallback below writes every byte twice — once by the allocator, once
  /// by the copy — a wasted ~32 kB/s memset for the length of the recording.
  /// `CMBlockBufferGetDataPointer` reports how much is contiguous at the offset,
  /// and anything short of the whole length means the buffer is segmented (which
  /// LPCM from this output is not, in practice) and the copying path has to run
  /// rather than be assumed away. Nil when neither read succeeds.
  static func copyBytes(from blockBuffer: CMBlockBuffer, length: Int) -> Data? {
    var contiguousLength = 0
    var totalLength = 0
    var pointer: UnsafeMutablePointer<Int8>?
    let located = unsafe CMBlockBufferGetDataPointer(
      blockBuffer,
      atOffset: 0,
      lengthAtOffsetOut: &contiguousLength,
      totalLengthOut: &totalLength,
      dataPointerOut: &pointer
    )
    if located == kCMBlockBufferNoErr, let contiguous = unsafe pointer, contiguousLength >= length {
      return unsafe Data(bytes: contiguous, count: length)
    }
    var copied = Data(count: length)
    let status = unsafe copied.withUnsafeMutableBytes { raw -> OSStatus in
      // Empty is excluded by the caller, so a nil base can't happen; answered as
      // a plain non-noErr status rather than trapping, since dropping the buffer
      // is this method's failure mode for every other copy problem too.
      guard let base = raw.baseAddress else {
        return OSStatus(-1)
      }
      return unsafe CMBlockBufferCopyDataBytes(
        blockBuffer, atOffset: 0, dataLength: length, destination: base
      )
    }
    return status == kCMBlockBufferNoErr ? copied : nil
  }
}

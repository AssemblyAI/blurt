import Foundation

@testable import BlurtEngine

extension AsyncStream where Element == Data {
  /// A finished feed carrying `pcm` as a single frame — what a mic stub hands
  /// the chunked upload in place of a live capture.
  ///
  /// One frame rather than several: the stubs exist to assert *what* reached the
  /// request, and the production framing (how many chunks, at what cadence) is
  /// the recorder's business, covered where the recorder is. Empty PCM yields
  /// nothing at all, so a stub with no audio produces an empty feed rather than
  /// a zero-length frame the upload would dutifully write.
  static func oneShot(_ pcm: Data) -> AsyncStream<Data> {
    AsyncStream { continuation in
      if !pcm.isEmpty { continuation.yield(pcm) }
      continuation.finish()
    }
  }
}

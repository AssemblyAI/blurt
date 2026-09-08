import Foundation

@testable import BlurtEngine

extension AsyncStream where Element == Data {
  /// A finished feed carrying `pcm` as a single frame — what a mic stub hands
  /// the chunked upload in place of a live capture.
  ///
  /// One frame rather than several: the stubs exist to assert *what* reached the
  /// request, and the production framing (how many chunks, at what cadence) is
  /// the recorder's business, covered where the recorder is.
  static func oneShot(_ pcm: Data) -> AsyncStream<Data> {
    AsyncStream { continuation in
      continuation.yield(pcm)
      continuation.finish()
    }
  }

  /// An already-finished feed — a capture that produced nothing. Spelled as its
  /// own name rather than `oneShot(Data())`, which would smuggle two meanings
  /// into one call and make a zero-length frame look intentional.
  static var finished: AsyncStream<Data> {
    AsyncStream { $0.finish() }
  }
}

extension AsyncThrowingStream where Element == Data, Failure == any Error {
  /// A finished body carrying `chunks` in order — the request-side twin of
  /// `AsyncStream.oneShot`, for driving `ChunkedRequestBody` without a capture.
  static func chunks(_ chunks: Data...) -> AsyncThrowingStream<Data, any Error> {
    AsyncThrowingStream { continuation in
      for chunk in chunks { continuation.yield(chunk) }
      continuation.finish()
    }
  }

  /// Yields `chunks`, then fails — a producer that cannot finish the body, which
  /// is what an unencodable `config` part looks like from the pipe's side.
  static func chunks(
    _ chunks: Data..., failingWith error: any Error
  ) -> AsyncThrowingStream<Data, any Error> {
    AsyncThrowingStream { continuation in
      for chunk in chunks { continuation.yield(chunk) }
      continuation.finish(throwing: error)
    }
  }
}

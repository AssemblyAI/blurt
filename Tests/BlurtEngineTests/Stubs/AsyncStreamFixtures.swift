import Foundation

@testable import BlurtEngine

extension AsyncStream where Element: Sendable {
  /// A finished feed carrying one element — a canned capture, or the single
  /// context value the session sends at release.
  ///
  /// Generic, and the only name for this: it was spelled three ways (`oneShot`
  /// for audio, `just` for context, and `oneShot(Data())` for "nothing"), which
  /// is two names and a hidden special case for one primitive.
  ///
  /// One element rather than several: the stubs exist to assert *what* reached
  /// the request, and the production framing (how many chunks, at what cadence)
  /// is the recorder's business, covered where the recorder is.
  static func oneShot(_ element: Element) -> AsyncStream {
    AsyncStream { continuation in
      continuation.yield(element)
      continuation.finish()
    }
  }

  /// An already-finished feed — a capture that produced nothing, or a context
  /// channel the session abandoned. Its own name, so a zero-length element
  /// never has to stand in for "no element".
  static var finished: AsyncStream {
    AsyncStream { $0.finish() }
  }
}

extension AsyncThrowingStream where Element == Data, Failure == any Error {
  /// A body carrying `chunks` in order, finishing cleanly or with `error` — the
  /// request-side twin of `AsyncStream.oneShot`, for driving
  /// `ChunkedRequestBody` without a capture behind it.
  ///
  /// `failingWith` defaults to nil rather than living in a second overload: the
  /// two differed only in `finish()` versus `finish(throwing:)`.
  static func chunks(
    _ chunks: Data..., failingWith error: (any Error)? = nil
  ) -> AsyncThrowingStream<Data, any Error> {
    AsyncThrowingStream { continuation in
      for chunk in chunks { continuation.yield(chunk) }
      if let error {
        continuation.finish(throwing: error)
      } else {
        continuation.finish()
      }
    }
  }
}

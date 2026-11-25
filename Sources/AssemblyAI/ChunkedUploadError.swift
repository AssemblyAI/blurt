import Foundation

/// Failures specific to feeding a streamed request body. Wrapped in
/// the caller's own error before reaching a UI (Blurt wraps it in
/// `BlurtError.sttFailed`).
enum ChunkedUploadError: Error, LocalizedError {
  /// The pipe closed before the whole body was written — `URLSession` gave up
  /// on the request while audio was still being produced.
  case bodyStreamClosed
  /// The platform refused to create the pipe the body is written through.
  case bodyStreamUnavailable

  var errorDescription: String? {
    switch self {
    case .bodyStreamClosed:
      return "The upload connection closed before the recording finished sending."

    case .bodyStreamUnavailable:
      return "Couldn't open an upload stream for the recording."
    }
  }
}

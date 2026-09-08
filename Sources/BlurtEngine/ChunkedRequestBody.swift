import Foundation

/// A `CFStream` bound pair standing in for a request body that does not exist
/// yet: `URLSession` reads `input` as the upload body while `drain` writes the
/// audio into `output` as the microphone produces it.
///
/// Why a bound pair rather than something nicer: as of the macOS 26 SDK there
/// is no `URLSession` API that accepts an `AsyncSequence` as a request body.
/// Every streaming-upload path — `URLRequest.httpBodyStream` and
/// `uploadTask(withStreamedRequest:)` alike — ultimately wants an
/// `InputStream`, so manufacturing one is unavoidable. `uploadTask` is the
/// documented path but has no `async` form, which would cost the whole
/// data-collecting/completion delegate; `httpBodyStream` keeps the
/// `data(for:delegate:)` ergonomics and pairs with a `needNewBodyStream`
/// delegate that refuses a replay (see `MetricsLogger`).
///
/// Not setting `Content-Length` is what makes the upload chunked: `URLSession`
/// falls back to `Transfer-Encoding: chunked` (or streamed HTTP/2 DATA frames)
/// when the body length is unknown, which is precisely the case a live
/// recording is in.
///
/// `@unchecked Sendable` by confinement: `input` is handed to `URLSession` in
/// `upload(for:streaming:delegate:)` and never touched here again, and `output`
/// is touched only by the single task running `drain`.
final class ChunkedRequestBody: @unchecked Sendable {
  /// `URLSession`'s end of the pair. Handed over unopened — `URLSession` opens
  /// it itself, and opening it here makes the upload fail.
  let input: InputStream
  private let output: OutputStream

  /// Bound-pair buffer size — one second of the 16 kHz mono S16LE geometry.
  ///
  /// Deliberately small. The buffer is not a place audio should accumulate: any
  /// byte sitting here when the user stops talking still has to reach the wire
  /// before the transcript can come back, so a generous buffer would quietly
  /// re-add the post-speech upload wait that streaming exists to remove. One
  /// second is enough to absorb the jitter between the capture callback's
  /// delivery cadence and the socket's, and no more. (The kernel's own socket
  /// send buffer sits behind this and is not ours to size.)
  private static let bufferSize = SyncSTTLimits.sampleRate * SyncSTTLimits.bytesPerSample

  /// How long to wait before re-checking a full pipe. Only reached while the
  /// uplink is behind the microphone, which is the case this whole path is for;
  /// 5 ms is well under the capture callback's own cadence, so a drained pipe is
  /// noticed long before the next frame arrives.
  private static let spaceRetry = Duration.milliseconds(5)

  /// Throws when `CFStreamCreateBoundPair` hands back a half-nil pair. It has
  /// no documented failure mode for a valid buffer size and the default
  /// allocator, but the alternative to checking is force-unwrapping a body the
  /// upload cannot proceed without.
  init() throws {
    var readStream: Unmanaged<CFReadStream>?
    var writeStream: Unmanaged<CFWriteStream>?
    CFStreamCreateBoundPair(nil, &readStream, &writeStream, CFIndex(Self.bufferSize))
    guard let readStream, let writeStream else {
      throw ChunkedUploadError.bodyStreamUnavailable
    }
    input = readStream.takeRetainedValue() as InputStream
    output = writeStream.takeRetainedValue() as OutputStream
  }

  /// Writes every chunk `body` produces into the pipe, in order, then closes it
  /// — and closing is what tells the server the multipart body is complete.
  ///
  /// Rethrows whatever `body` throws, so a producer failure (e.g. the `config`
  /// part failing to encode) surfaces as an error instead of a body that simply
  /// stops mid-part and leaves the server to reject a truncated request.
  func drain(_ body: AsyncThrowingStream<Data, any Error>) async throws {
    output.open()
    defer { output.close() }
    for try await chunk in body {
      try await write(chunk)
    }
  }

  /// Writes one chunk, waiting out backpressure rather than dropping audio.
  ///
  /// `OutputStream.write` on a bound pair takes only what fits, so a partial
  /// write is normal and the remainder has to be retried — dropping it would
  /// desynchronise the multipart body, not merely lose a few milliseconds of
  /// sound. Polling `hasSpaceAvailable` (rather than scheduling the stream on a
  /// run loop and waiting for `.hasSpaceAvailable`) keeps this a plain async
  /// function: it suspends the task instead of parking a thread, so a stalled
  /// uplink costs nothing but the retry ticks.
  private func write(_ chunk: Data) async throws {
    var remaining = chunk
    while !remaining.isEmpty {
      try Task.checkCancellation()
      guard output.hasSpaceAvailable else {
        try await Task.sleep(for: Self.spaceRetry)
        continue
      }
      let written = remaining.withUnsafeBytes { raw -> Int in
        guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return -1 }
        return output.write(base, maxLength: remaining.count)
      }
      guard written > 0 else {
        // 0 means the reader went away, negative means a real stream error;
        // either way the body can never be completed, so fail rather than spin.
        throw output.streamError ?? ChunkedUploadError.bodyStreamClosed
      }
      remaining = remaining.dropFirst(written)
    }
  }
}

/// Failures specific to feeding a streamed request body. Wrapped in
/// `BlurtError.sttFailed` before reaching the UI, like `AssemblyAIError`.
enum ChunkedUploadError: Error, LocalizedError {
  /// The pipe closed before the whole body was written — `URLSession` gave up
  /// on the request while audio was still being produced.
  case bodyStreamClosed
  /// The platform refused to create the pipe the body is written through.
  case bodyStreamUnavailable
  /// A release reached the transcript step with no request in flight — the
  /// recording was never uploaded.
  case uploadNeverStarted
  /// `URLSession` asked for the body a second time (an auth challenge, a
  /// redirect, a connection retry). A recording that has already been streamed
  /// cannot be replayed, so the request fails here instead of silently
  /// uploading nothing.
  case bodyNotReplayable

  var errorDescription: String? {
    switch self {
    case .bodyStreamClosed:
      return "The upload connection closed before the recording finished sending."
    case .bodyNotReplayable:
      return "The upload had to be restarted, which a live recording can't do."
    case .bodyStreamUnavailable:
      return "Couldn't open an upload stream for the recording."
    case .uploadNeverStarted:
      return "The recording wasn't uploaded."
    }
  }
}

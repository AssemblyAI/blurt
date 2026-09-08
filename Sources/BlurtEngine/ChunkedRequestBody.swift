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
  private static let bufferSize = SyncSTTLimits.pcmBytes(forSeconds: 1)

  /// Backpressure re-check interval: starts here and doubles up to
  /// `maxSpaceRetry` while the pipe stays full, resetting after every write that
  /// moves bytes.
  ///
  /// A fixed 5 ms was 200 wake-ups a second for the whole duration of a slow
  /// upload — which is not an edge case but the case this feature exists for.
  /// Backing off costs nothing: the pipe in front of this loop is a full second
  /// deep, so even the ceiling is an order of magnitude under its drain time,
  /// while the first retries stay fine-grained enough to keep up with a
  /// microphone that delivers roughly ten buffers a second.
  private static let minSpaceRetry = Duration.milliseconds(5)
  private static let maxSpaceRetry = Duration.milliseconds(40)

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
    var retry = Self.minSpaceRetry
    while !remaining.isEmpty {
      try Task.checkCancellation()
      guard output.hasSpaceAvailable else {
        // A pipe that has been torn down — `URLSession` abandoned the body after
        // an early response, or asked for a replay it cannot have — can stop
        // accepting bytes without ever reporting itself writable *or* returning
        // a short write, so the zero-write branch below would never be reached
        // and this would poll until the task was cancelled. Treat a dead stream
        // as the failure it is.
        switch output.streamStatus {
        case .error, .atEnd, .closed:
          throw output.streamError ?? ChunkedUploadError.bodyStreamClosed
        default:
          try await Task.sleep(for: retry)
          retry = min(retry * 2, Self.maxSpaceRetry)
          continue
        }
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
      retry = Self.minSpaceRetry
    }
  }

  /// Streams `body` as `request`'s HTTP body, with `fetch` standing in for
  /// `URLSession.data(for:delegate:)`.
  ///
  /// Here, behind an injectable `fetch`, rather than inside the `URLSession`
  /// conformance, because what this decides is *policy*: whether an early 401
  /// reaches the user as an auth failure or as a broken pipe, and whether a
  /// producer failure outranks the server's own reply. Left in the conformance
  /// that every test double replaces, none of it was reachable from a test —
  /// and it is the most delicate code in the upload.
  static func send(
    _ request: URLRequest,
    body: AsyncThrowingStream<Data, any Error>,
    delegate: (any URLSessionTaskDelegate)?,
    fetch: (URLRequest, (any URLSessionTaskDelegate)?) async throws -> (Data, URLResponse)
  ) async throws -> (Data, URLResponse) {
    let pipe = try ChunkedRequestBody()
    var streamed = request
    streamed.httpBodyStream = pipe.input
    let writer = Task { try await pipe.drain(body) }
    // Covers every exit: a thrown response, and cancellation while the recording
    // is still being written. Without it an abandoned dictation would leave the
    // writer feeding a request nobody is waiting for.
    defer { writer.cancel() }
    let (responseData, response) = try await fetch(streamed, delegate)
    // Cancel the writer rather than joining it, and do it before asking for its
    // outcome. The response can arrive while the body is still being written —
    // an early 401 or 429 is the whole reason the writer is a sibling task — and
    // a pipe the transport has already torn down may simply stop accepting bytes
    // without ever reporting itself writable. Joining first would then park here
    // indefinitely, with the `defer` above not yet reached.
    writer.cancel()
    let outcome = await writer.result
    // A *producer* failure (the `config` part failing to encode, say) truncates
    // the body, and the server answers with some generic 4xx that doesn't name
    // the cause — so that error wins. Everything else defers to the response.
    //
    // Which means two writer errors are explicitly not preferred, because both
    // are symptoms of the response rather than causes of it. `CancellationError`
    // is this method cancelling its own writer above. `bodyStreamClosed` is the
    // transport tearing the pipe down on the way to delivering an early status,
    // which can beat that cancel — and preferring it turned an expired API key
    // into "the upload connection closed before the recording finished
    // sending", exactly the substitution this policy exists to prevent.
    if case .failure(let error) = outcome, !(error is CancellationError),
      !isPipeTeardown(error),
      let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode)
    {
      throw error
    }
    return (responseData, response)
  }

  /// Whether `error` is the pipe going away rather than the body failing to be
  /// produced — the distinction the precedence rule above turns on.
  private static func isPipeTeardown(_ error: any Error) -> Bool {
    if case ChunkedUploadError.bodyStreamClosed = error { return true }
    // The `OutputStream`'s own error for a reader that has gone: same meaning,
    // different origin, and it reaches `write` first when the stream reports one.
    return (error as? URLError)?.code == .networkConnectionLost
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

  var errorDescription: String? {
    switch self {
    case .bodyStreamClosed:
      return "The upload connection closed before the recording finished sending."
    case .bodyStreamUnavailable:
      return "Couldn't open an upload stream for the recording."
    case .uploadNeverStarted:
      return "The recording wasn't uploaded."
    }
  }
}

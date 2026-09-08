import Foundation

/// The `URLSession` calls the AssemblyAI clients make (`AssemblyAITranscriber`,
/// `APIKeyValidator`), behind a seam so tests substitute a per-instance fake
/// instead of registering a process-global `URLProtocol`.
public protocol HTTPTransport: Sendable {
  func data(for request: URLRequest) async throws -> (Data, URLResponse)

  /// Upload a request body that is still being produced — the dictation
  /// request, whose audio does not exist yet when the request opens.
  ///
  /// `body` is consumed in order and the request completes when it finishes, so
  /// finishing the stream is what signals end-of-audio. Nothing sets
  /// `Content-Length`: an unknown body length is what makes `URLSession` frame
  /// the upload chunked, which is the entire point — the bytes go out while the
  /// user is still speaking instead of after they stop.
  ///
  /// Replaces the `Data`-bodied `upload(for:from:delegate:)` outright rather
  /// than sitting beside it: the dictation request was its only caller, and a
  /// buffered path left in place is a fallback waiting to be taken.
  func upload(
    for request: URLRequest, streaming body: AsyncThrowingStream<Data, any Error>,
    delegate: (any URLSessionTaskDelegate)?
  ) async throws -> (Data, URLResponse)
}

extension URLSession: HTTPTransport {
  /// Streams `body` through a `CFStream` bound pair set as the request's
  /// `httpBodyStream` (see `ChunkedRequestBody` for why that is the only shape
  /// available).
  ///
  /// The writer runs as a sibling task so the response is read *while* the body
  /// is still being written — the endpoint can answer mid-upload (a 401 or 429
  /// lands as soon as authorization resolves), and a client that finished
  /// writing before reading would surface a broken pipe instead of the real
  /// status.
  public func upload(
    for request: URLRequest, streaming body: AsyncThrowingStream<Data, any Error>,
    delegate: (any URLSessionTaskDelegate)?
  ) async throws -> (Data, URLResponse) {
    let pipe = try ChunkedRequestBody()
    var streamed = request
    streamed.httpBodyStream = pipe.input
    let writer = Task { try await pipe.drain(body) }
    // Covers every exit: a thrown response, and cancellation while the recording
    // is still being written. Without it an abandoned dictation would leave the
    // writer feeding a request nobody is waiting for.
    defer { writer.cancel() }
    let (body, response) = try await data(for: streamed, delegate: delegate)
    // Cancel the writer rather than joining it, and do it before asking for its
    // outcome. The response can arrive while the body is still being written —
    // an early 401 or 429 is the whole reason the writer is a sibling task — and
    // a pipe `URLSession` has already torn down may simply stop accepting bytes
    // without ever reporting itself writable. Joining first would then park here
    // indefinitely, with the `defer` above not yet reached.
    writer.cancel()
    let outcome = await writer.result
    // A producer failure (the `config` part failing to encode, say) truncates
    // the body, and the server answers with some generic 4xx that doesn't name
    // the cause — so the writer's error wins there. On a 2xx the body plainly
    // arrived whole, and a late write failure is noise that would mask a
    // perfectly good transcript; on a non-2xx with no writer error the server's
    // own message is what surfaces, via the caller's status check.
    if case .failure(let error) = outcome, !(error is CancellationError),
      let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode)
    {
      throw error
    }
    return (body, response)
  }
}

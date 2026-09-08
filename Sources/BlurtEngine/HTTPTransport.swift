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
    let result = try await data(for: streamed, delegate: delegate)
    // Ask the writer for its outcome *after* the response, not instead of it. A
    // producer failure truncates the body, which the server reports as some
    // generic 400 — the writer's own error is the one that names the cause, so
    // it wins when both exist.
    try await writer.value
    return result
  }
}

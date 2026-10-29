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
  /// buffered path left in place is a fallback waiting to be taken. The one
  /// buffered dictation request there is — the whole recording to
  /// `/v1/transcribe`, sent only after the streaming route refuses a recording
  /// past its 120 s cap — goes through `data(for:)` with an `httpBody`, so it
  /// cannot be mistaken for, or substituted into, this streaming path.
  func upload(
    for request: URLRequest, streaming body: AsyncThrowingStream<Data, any Error>,
    delegate: (any URLSessionTaskDelegate)?
  ) async throws -> (Data, URLResponse)
}

extension URLSession: HTTPTransport {
  /// Forwards to `ChunkedRequestBody.send`, which owns the pipe and the
  /// error-precedence policy — see there for why that logic does not live in
  /// this conformance.
  public func upload(
    for request: URLRequest, streaming body: AsyncThrowingStream<Data, any Error>,
    delegate: (any URLSessionTaskDelegate)?
  ) async throws -> (Data, URLResponse) {
    try await ChunkedRequestBody.send(request, body: body, delegate: delegate) { streamed, hook in
      try await self.data(for: streamed, delegate: hook)
    }
  }
}

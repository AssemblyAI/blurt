import Foundation
import Testing

@testable import BlurtEngine

/// The upload's transport half: the bound-pair body pipe, the send policy that
/// decides which of two errors a caller sees, and the per-request bookkeeping.
/// Split from `ChunkedUploadTests` (which owns the session behaviour) for the
/// lint file-length budget.
@Suite("Chunked request body", .timeLimit(.minutes(1)))
struct ChunkedRequestBodyTests {

  @Test("the body pipe delivers every chunk, in order")
  func pipeDeliversChunksInOrder() async throws {
    let body = try ChunkedRequestBody()
    let reader = readAll(from: body)

    try await body.drain(.chunks(Data("first".utf8), Data("second".utf8), Data("third".utf8)))

    #expect(await reader.value == Data("firstsecondthird".utf8))
  }

  @Test("a producer failure surfaces rather than truncating the body silently")
  func producerFailurePropagates() async throws {
    let body = try ChunkedRequestBody()
    let reader = readAll(from: body)

    // Stands in for the `config` part failing to encode: the body can no longer
    // be completed, and the server would only report a generic 400. A local
    // error rather than one of the transport's own, so the test says "the
    // producer failed" without borrowing a case that means something else.
    await #expect(throws: ProducerFailure.self) {
      try await body.drain(.chunks(Data("partial".utf8), failingWith: ProducerFailure()))
    }
    _ = await reader.value
  }

  @Test("a reader that goes away fails the write instead of dropping audio")
  func closedReaderFailsTheWrite() async throws {
    let body = try ChunkedRequestBody()
    // Stands in for the transport abandoning the body — an early 401, or a
    // replay it asked for and was refused. The pipe can then stop accepting
    // bytes without ever reporting itself writable, so this has to fail rather
    // than poll forever or silently discard the rest of the recording.
    body.input.open()
    body.input.close()

    await #expect(throws: (any Error).self) {
      try await body.drain(.chunks(Data(count: 128 * 1024)))
    }
  }

  @Test("cancelling the upload stops the writer instead of parking on a full pipe")
  func cancellationUnblocksTheWriter() async throws {
    let body = try ChunkedRequestBody()
    // Nobody ever reads, so the pipe fills and the writer lands in its
    // backpressure loop. Cancellation is what has to get it out — `send` relies
    // on exactly this when the response arrives before the body is done.
    let writer = Task { try await body.drain(.chunks(Data(count: 512 * 1024))) }
    // Let it reach the loop before cancelling, so this exercises the wait rather
    // than the pre-flight `checkCancellation`.
    try await Task.sleep(for: .milliseconds(50))
    writer.cancel()

    await #expect(throws: CancellationError.self) { try await writer.value }
  }

  @Test("an early failure response outranks the torn-down pipe it causes")
  func earlyResponseWinsOverTheWriterError() async throws {
    // Authorization resolves concurrently with the upload, so a 401 can land
    // while the body is still being written — and writing then fails, because
    // the transport has torn the pipe down. The user has to see the status that
    // explains the failure, not "the upload connection closed". The body here is
    // far larger than the pipe, so the writer is certainly mid-write.
    let (data, response) = try await ChunkedRequestBody.send(
      URLRequest(url: URL(staticString: "https://example.invalid")),
      body: .chunks(Data(count: 512 * 1024)),
      delegate: nil
    ) { request, _ in
      let url = try #require(request.url)
      let response = try #require(
        HTTPURLResponse(url: url, statusCode: 401, httpVersion: nil, headerFields: nil))
      return (Data(#"{"detail":"Invalid API key"}"#.utf8), response)
    }

    #expect((response as? HTTPURLResponse)?.statusCode == 401)
    #expect(!data.isEmpty)
  }

  @Test("a pipe torn down on the way to a 401 does not outrank the 401")
  func pipeTeardownDoesNotMaskTheStatus() async throws {
    // What a real early auth failure looks like: the transport closes the body
    // stream and *then* delivers the status. The writer's "the reader went away"
    // error can beat `send`'s own cancel, and preferring it turned an expired
    // API key into "the upload connection closed before the recording finished
    // sending" — the substitution the precedence rule exists to prevent.
    let (data, response) = try await ChunkedRequestBody.send(
      URLRequest(url: URL(staticString: "https://example.invalid")),
      body: .chunks(Data(count: 512 * 1024)),
      delegate: nil
    ) { request, _ in
      request.httpBodyStream?.open()
      request.httpBodyStream?.close()
      // Give the writer a moment to notice and fail before the status lands.
      try await Task.sleep(for: .milliseconds(30))
      let url = try #require(request.url)
      let unauthorized = try #require(
        HTTPURLResponse(url: url, statusCode: 401, httpVersion: nil, headerFields: nil))
      return (Data(#"{"detail":"Invalid API key"}"#.utf8), unauthorized)
    }

    #expect((response as? HTTPURLResponse)?.statusCode == 401)
    #expect(!data.isEmpty)
  }

  @Test("URLSession is refused a second copy of the body, never handed an empty one")
  func replayIsRefused() async {
    // One of the three no-fallback guarantees. URLSession asks for a fresh body
    // stream whenever it has to send the request again — an auth challenge, a
    // 307, a connection retry it handles internally. A recording that has
    // already been streamed is gone, so the honest answer is nil, which fails
    // the request. Handing back anything else would re-send the dictation with
    // no audio in it and return a blank transcript.
    let delegate = DictationUploadDelegate()
    // Never resumed — the delegate ignores both arguments, so an idle task is
    // enough to exercise the contract without touching the network.
    let task = URLSession.shared.dataTask(with: URL(staticString: "https://example.invalid"))

    let replacement = await delegate.urlSession(.shared, needNewBodyStreamForTask: task)

    #expect(replacement == nil)
  }

  @Test("upload progress accounts the audio it has actually sent")
  func uploadProgressAccountsAudio() throws {
    let progress = UploadProgress()
    // Nothing sent yet: there is no "last frame" instant to measure post-speech
    // latency from, which is what nil means to the log line.
    #expect(progress.audioBytes == 0)
    #expect(progress.lastFrameAt == nil)

    progress.recordFrame(bytes: 3_200)
    let first = progress.lastFrameAt
    #expect(progress.audioBytes == 3_200)
    #expect(first != nil)

    progress.recordFrame(bytes: 1_600)
    // Bytes accumulate; the instant tracks the *latest* frame, because that is
    // the one the user stopped talking at. Both unwrapped rather than
    // `?? .now`-defaulted, which would compare `.now >= .now` and pass whatever
    // the code did.
    #expect(progress.audioBytes == 4_800)
    let earlier = try #require(first)
    let later = try #require(progress.lastFrameAt)
    #expect(later >= earlier)
  }
}

extension ChunkedRequestBodyTests {
  /// Stands in for the transport: owns the pipe's read end and drains it until
  /// the writer closes, which is what marks the body complete.
  private func readAll(from body: ChunkedRequestBody) -> Task<Data, Never> {
    Task.detached {
      body.input.open()
      defer { body.input.close() }
      var received = Data()
      var buffer = [UInt8](repeating: 0, count: 64)
      while true {
        let read = body.input.read(&buffer, maxLength: buffer.count)
        if read <= 0 { break }
        received.append(contentsOf: buffer[0..<read])
      }
      return received
    }
  }
}

/// Stands in for whatever the body producer might fail with — an unencodable
/// `config` part, in production.
private struct ProducerFailure: Error {}

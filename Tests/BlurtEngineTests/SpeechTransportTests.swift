import Foundation
import Synchronization
import Testing

@testable import AssemblyAI
@testable import BlurtAssemblyAI
@testable import BlurtEngine

/// The TTS client's failures through the fake transport, and the production
/// `URLSession` streaming path through a `URLProtocol` on a private session —
/// the one place a real cancellation's `URLError(.cancelled)` can show up.
@Suite("TTS transport and errors", .serialized, .timeLimit(.minutes(1)))
struct SpeechTransportTests {
  private func synthesizer(_ transport: any SpeechTransport) -> AssemblyAISpeechSynthesizer {
    AssemblyAISpeechSynthesizer(apiKeyProvider: { "k" }, transport: transport)
  }

  private func collect(_ synth: AssemblyAISpeechSynthesizer, _ audio: ValueBox<Data>) async throws {
    for try await chunk in synth.speech(for: "Read this.") { audio.value.append(chunk) }
  }

  // MARK: - Error paths

  @Test("a request that times out, before or during the body, reads as 'stopped responding'")
  func timeouts() async {
    await #expect(throws: SpeechSynthesisError.timedOut) {
      try await collect(synthesizer(FakeSpeechTransport(failing: URLError(.timedOut))), ValueBox(Data()))
    }
    let audio = ValueBox(Data())
    let stalled = FakeSpeechTransport(end: .fail(URLError(.timedOut))) { _ in (200, [Data([1, 0])]) }
    await #expect(throws: SpeechSynthesisError.timedOut) { try await collect(synthesizer(stalled), audio) }
    #expect(audio.value == Data([1, 0]), "the audio before the stall still plays")
  }

  @Test("a connection dropped mid-body fails with its own error, after the audio that arrived")
  func droppedMidBody() async {
    let audio = ValueBox(Data())
    let dropped = FakeSpeechTransport(end: .fail(URLError(.networkConnectionLost))) { _ in (200, [Data([1, 0])]) }
    await #expect(throws: URLError.self) { try await collect(synthesizer(dropped), audio) }
    #expect(audio.value == Data([1, 0]))
  }

  @Test("an error body is read only so far: a huge or stalled one still fails promptly")
  func errorBodyCap() async {
    let page = Data(repeating: 0x3C, count: 1_024)
    let endless = FakeSpeechTransport(end: .hang) { _ in (502, Array(repeating: page, count: 70)) }
    await #expect(throws: SpeechSynthesisError.server("HTTP 502")) {
      try await collect(synthesizer(endless), ValueBox(Data()))
    }
  }

  @Test("an error body with a message but no code reports the message")
  func messageWithoutCode() {
    let body = Data(#"{"message":"Slow down"}"#.utf8)
    #expect(SpeechClient.failure(status: 429, body: body) == "Slow down")
  }

  // MARK: - The URLSession path

  private func session() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ScriptedSpeechProtocol.self]
    return URLSession(configuration: configuration)
  }

  @Test("URLSession streams the body through to the audio")
  func urlSessionStreams() async throws {
    ScriptedSpeechProtocol.play(.respond(status: 200, chunks: [Data([1, 0, 2, 0]), Data([3, 0])], finishes: true))
    let audio = ValueBox(Data())
    try await collect(synthesizer(session()), audio)
    #expect(audio.value == Data([1, 0, 2, 0, 3, 0]))
  }

  @Test("URLSession: a refused request reports the body's reason")
  func urlSessionRefused() async {
    let body = Data(#"{"code":"unauthorized","message":"Invalid API key"}"#.utf8)
    ScriptedSpeechProtocol.play(.respond(status: 401, chunks: [body], finishes: true))
    await #expect(throws: SpeechSynthesisError.server("(unauthorized) Invalid API key")) {
      try await collect(synthesizer(session()), ValueBox(Data()))
    }
  }

  @Test("URLSession: a failure before the response throws rather than hanging")
  func urlSessionFailsEarly() async {
    ScriptedSpeechProtocol.play(.fail(URLError(.notConnectedToInternet)))
    await #expect(throws: URLError.self) { try await collect(synthesizer(session()), ValueBox(Data())) }
  }

  @Test("URLSession: a connection dropped mid-body fails after the audio that arrived")
  func urlSessionDropsMidBody() async {
    ScriptedSpeechProtocol.play(.respondThenFail(chunk: Data([1, 0]), URLError(.networkConnectionLost)))
    let audio = ValueBox(Data())
    await #expect(throws: URLError.self) { try await collect(synthesizer(session()), audio) }
    #expect(audio.value == Data([1, 0]))
  }

  @Test("URLSession: a request asked for by an already-cancelled task throws at once and is never sent")
  func urlSessionCancelledBeforeStart() async throws {
    ScriptedSpeechProtocol.play(.respond(status: 200, chunks: [Data([1, 0])], finishes: false))
    let session = session()
    let request = try SpeechClient().request(for: "Read this.", voiceID: "v", apiKey: "k")
    let attempt = Task {
      unsafe withUnsafeCurrentTask { unsafe $0?.cancel() }
      return try await session.stream(request)
    }
    await #expect(throws: CancellationError.self) { _ = try await attempt.value }
    #expect(!ScriptedSpeechProtocol.started, "a cancelled read should never reach the service")
  }

  @Test("a cancellation that lands before the wait arms is handed over, and the request is never started")
  func delegateCancelledBeforeArm() async {
    let (body, feed) = AsyncThrowingStream<Data, any Error>.makeStream()
    let delegate = SpeechStreamDelegate(body: feed)
    delegate.fail(CancellationError())
    let started = ValueBox(true)
    await #expect(throws: CancellationError.self) {
      _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HTTPURLResponse, Error>) in
        started.value = delegate.arm(continuation)
      }
    }
    #expect(!started.value)
    await #expect(throws: CancellationError.self) {
      for try await _ in body {
        // Drained for how the stream ends; its elements don't matter.
      }
    }
  }

  @Test("once the head is delivered, later outcomes don't resume the wait again")
  func delegateSettlesOnce() async throws {
    let (_, feed) = AsyncThrowingStream<Data, any Error>.makeStream()
    let delegate = SpeechStreamDelegate(body: feed)
    let url = SpeechClient.endpoint
    let head = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
    let response: HTTPURLResponse = try await withCheckedThrowingContinuation { continuation in
      #expect(delegate.arm(continuation))
      delegate.settle(.success(head))
      delegate.fail(CancellationError())
      delegate.settle(.failure(URLError(.cancelled)))
    }
    #expect(response.statusCode == 200)
  }

  @Test("URLSession: stopping a read cancels its request and reads as a cancellation, not a failure")
  func urlSessionCancellation() async throws {
    ScriptedSpeechProtocol.play(.respond(status: 200, chunks: [Data([1, 0])], finishes: false))
    let sink = RecordingSink()
    let speaker = SelectionSpeaker(
      synthesizer: synthesizer(session()),
      llm: ReadAloudLLM(apiKeyProvider: { "k" }, transport: FakeHTTPTransport.failing(with: URLError(.timedOut)))
    ) { _ in sink }
    let reading = Task { try await speaker.speak("Read this.", style: .standard, onLevel: nil) }
    // Cancelled mid-body: once the first audio has reached the sink, rather
    // than a fixed moment after the request started that a slow run can miss.
    while sink.chunks.isEmpty { await Task.yield() }
    reading.cancel()
    await #expect(throws: CancellationError.self) { try await reading.value }
    // Unbounded, as the suite's time limit bounds it: a request left
    // synthesizing fails there, and a slow URLSession teardown doesn't.
    while !ScriptedSpeechProtocol.stopped { await Task.yield() }
  }
}

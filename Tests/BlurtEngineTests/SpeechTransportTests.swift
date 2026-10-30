import Foundation
import Synchronization
import Testing

@testable import AssemblyAI
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
    #expect(AssemblyAISpeechSynthesizer.failure(status: 429, body: body) == "Slow down")
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

  @Test("URLSession: stopping a read cancels its request and reads as a cancellation, not a failure")
  func urlSessionCancellation() async throws {
    ScriptedSpeechProtocol.play(.respond(status: 200, chunks: [Data([1, 0])], finishes: false))
    let speaker = SelectionSpeaker(
      synthesizer: synthesizer(session()),
      llm: ReadAloudLLM(apiKeyProvider: { "k" }, transport: FakeHTTPTransport.failing(with: URLError(.timedOut))),
      makeSink: { _ in RecordingSink() })
    let reading = Task { try await speaker.speak("Read this.", style: .standard, onLevel: nil) }
    while !ScriptedSpeechProtocol.started { await Task.yield() }
    try await Task.sleep(for: .milliseconds(50))
    reading.cancel()
    await #expect(throws: CancellationError.self) { try await reading.value }
    let deadline = ContinuousClock.now + .seconds(5)
    while !ScriptedSpeechProtocol.stopped, ContinuousClock.now < deadline { await Task.yield() }
    #expect(ScriptedSpeechProtocol.stopped, "the request should be cancelled, not left synthesizing")
  }
}

/// A `URLProtocol` playing one scripted response, registered only on the
/// private sessions `SpeechTransportTests` builds (never globally).
final class ScriptedSpeechProtocol: URLProtocol, @unchecked Sendable {
  enum Script: Sendable {
    case respond(status: Int, chunks: [Data], finishes: Bool)
    case respondThenFail(chunk: Data, URLError)
    case fail(URLError)
  }

  private struct State {
    var script = Script.fail(URLError(.unknown))
    var started = false
    var stopped = false
  }

  private static let state = Mutex(State())

  static func play(_ script: Script) {
    state.withLock { $0 = State(script: script) }
  }

  static var started: Bool { state.withLock(\.started) }
  static var stopped: Bool { state.withLock(\.stopped) }

  override static func canInit(with request: URLRequest) -> Bool { true }
  override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let script = Self.state.withLock { state in
      state.started = true
      return state.script
    }
    let url = request.url ?? AssemblyAISpeechSynthesizer.endpoint
    switch script {
    case .respond(let status, let chunks, let finishes):
      respond(status: status, url: url)
      for chunk in chunks { client?.urlProtocol(self, didLoad: chunk) }
      if finishes { client?.urlProtocolDidFinishLoading(self) }
    case .respondThenFail(let chunk, let error):
      respond(status: 200, url: url)
      client?.urlProtocol(self, didLoad: chunk)
      // A moment later, as a real connection drops after audio has flowed:
      // failing in the same instant, URLSession reports only the failure.
      DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { [self] in
        client?.urlProtocol(self, didFailWithError: error)
      }
    case .fail(let error):
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  override func stopLoading() {
    Self.state.withLock { $0.stopped = true }
  }

  /// With the content type the service sends: without one, URLSession sniffs
  /// the body before reporting the response, holding it back until enough of
  /// the body (or its end) arrives.
  private func respond(status: Int, url: URL) {
    let type = status == 200 ? "audio/pcm;rate=24000;channels=1" : "application/json"
    guard
      let response = HTTPURLResponse(
        url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": type])
    else { return }
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
  }
}

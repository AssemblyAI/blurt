import Foundation
import Synchronization
import Testing

@testable import AssemblyAI
@testable import BlurtEngine

@Suite("SelectionSpeaker")
struct SelectionSpeakerTests {
  private let fastSkipping = ReadAloudStyle(rate: 2, skipsJargon: true)

  private func speaker(
    _ transport: any SpeechTransport,
    sink: RecordingSink,
    gateway: any HTTPTransport = FakeHTTPTransport.failing(with: URLError(.notConnectedToInternet)),
    rate: ValueBox<Double?> = ValueBox(nil)
  ) -> SelectionSpeaker {
    SelectionSpeaker(
      synthesizer: AssemblyAISpeechSynthesizer(apiKeyProvider: { "k" }, transport: transport),
      llm: ReadAloudLLM(apiKeyProvider: { "k" }, transport: gateway)
    ) { played in
      rate.value = played
      return sink
    }
  }

  @Test("plays every chunk in order, then drains")
  func plays() async throws {
    let sink = RecordingSink()
    let transport = FakeSpeechTransport { _ in (200, [Data([1, 0]), Data([2, 0])]) }
    try await speaker(transport, sink: sink).speak("The first sentence here. And the second one.")
    #expect(sink.chunks == [Data([1, 0]), Data([2, 0])])
    #expect(sink.drained)
  }

  @Test("the meter hears the sink's level while it plays, then a final 0")
  func meter() async throws {
    let levels = ValueBox<[Float]>([])
    let sink = LevelSink(level: 0.6)
    let speaker = SelectionSpeaker(
      synthesizer: AssemblyAISpeechSynthesizer(apiKeyProvider: { "k" }, transport: FakeSpeechTransport()),
      llm: ReadAloudLLM(apiKeyProvider: { "k" }, transport: FakeHTTPTransport.failing(with: URLError(.timedOut)))
    ) { _ in sink }
    try await speaker.speak("Say something here.") { level in levels.value.append(level) }
    #expect(levels.value.last == 0)
    #expect(levels.value.dropLast().allSatisfy { $0 == 0.6 })
  }

  @Test("a synthesis failure silences playback and surfaces the error")
  func failure() async {
    let sink = RecordingSink()
    let transport = FakeSpeechTransport { _ in (500, [Data(#"{"message":"boom"}"#.utf8)]) }
    await #expect(throws: SpeechSynthesisError.server("boom")) {
      try await speaker(transport, sink: sink).speak("Say something here.")
    }
    #expect(sink.stopped)
    #expect(!sink.drained)
  }

  @Test("cancelling the speaking task stops playback")
  func cancellation() async {
    let sink = RecordingSink()
    let transport = HangingSpeechTransport()
    let speaking = Task { try await speaker(transport, sink: sink).speak("Say something here.") }
    while !transport.asked { await Task.yield() }
    speaking.cancel()
    _ = await speaking.result
    #expect(sink.stopped)
  }

  @Test("the standard style reads the selection verbatim at natural pace, with no gateway call")
  func standardStyle() async throws {
    let sink = RecordingSink()
    let transport = FakeSpeechTransport()
    let calls = Counter()
    let gateway = FakeHTTPTransport { _ in
      _ = calls.next()
      return (200, completion("unused"))
    }
    let rate = ValueBox<Double?>(nil)
    try await speaker(transport, sink: sink, gateway: gateway, rate: rate).speak("Run `npm ci` first.")
    #expect(transport.spoken == ["Run `npm ci` first."])
    #expect(rate.value == 1)
    #expect(calls.value == 0)
  }

  @Test("skipping jargon speaks the gateway's rewrite, at the style's rate")
  func skippingRewrites() async throws {
    let sink = RecordingSink()
    let transport = FakeSpeechTransport()
    let gateway = FakeHTTPTransport { _ in (200, completion("Run the command first.")) }
    let rate = ValueBox<Double?>(nil)
    try await speaker(transport, sink: sink, gateway: gateway, rate: rate)
      .speak("Run `npm ci --prefer-offline` first.", style: fastSkipping)
    #expect(transport.spoken == ["Run the command first."])
    #expect(rate.value == 2)
    #expect(sink.drained)
  }

  @Test("the style's voice names each request's voice_id, for reads and answers alike")
  func voice() async throws {
    let transport = FakeSpeechTransport()
    let speaker = SelectionSpeaker(
      synthesizer: AssemblyAISpeechSynthesizer(apiKeyProvider: { "k" }, transport: transport),
      llm: ReadAloudLLM(
        apiKeyProvider: { "k" }, transport: FakeHTTPTransport { _ in (200, completion("An answer.")) }
      )
    ) { _ in RecordingSink() }
    let style = ReadAloudStyle(rate: 1, skipsJargon: false, voiceID: "aai-buford")
    try await speaker.speak("Read this.", style: style)
    try await speaker.answer("Explain.", about: "x", style: style)
    let voices = transport.requests.map { request in
      (request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any])?["voice_id"]
        as? String
    }
    #expect(voices == ["aai-buford", "aai-buford"])
  }

  @Test("a failed rewrite falls back to reading the selection verbatim")
  func rewriteFailureFallsBack() async throws {
    let sink = RecordingSink()
    let transport = FakeSpeechTransport()
    let gateway = FakeHTTPTransport { _ in (503, Data()) }
    try await speaker(transport, sink: sink, gateway: gateway).speak("Email jo@example.com today.", style: fastSkipping)
    #expect(transport.spoken == ["Email jo@example.com today."])
  }

  @Test("an answer is spoken as the gateway wrote it, at the style's rate")
  func answers() async throws {
    let sink = RecordingSink()
    let transport = FakeSpeechTransport()
    let gateway = FakeHTTPTransport { _ in (200, completion("It reports a strong quarter.")) }
    let rate = ValueBox<Double?>(nil)
    try await speaker(transport, sink: sink, gateway: gateway, rate: rate)
      .answer("Summarize this.", about: "Revenue rose `12%` in Q3.", style: fastSkipping)
    // One gateway call (the answer, not a listening rewrite of it), then speech.
    #expect(transport.spoken == ["It reports a strong quarter."])
    #expect(rate.value == 2)
  }

  @Test("a failed answer surfaces its error and makes no TTS request")
  func answerFailure() async {
    let sink = RecordingSink()
    let transport = FakeSpeechTransport()
    let gateway = FakeHTTPTransport { _ in (503, Data()) }
    await #expect(throws: ReadAloudLLMError.status(503)) {
      try await speaker(transport, sink: sink, gateway: gateway).answer("Explain.", about: "x", style: .standard)
    }
    #expect(transport.requests.isEmpty)
  }

  @Test("a stop during the rewrite plays nothing, rather than falling back")
  func cancelledDuringRewrite() async {
    let sink = RecordingSink()
    let transport = FakeSpeechTransport()
    let gateway = HangingTransport()
    let speaking = Task {
      try await speaker(transport, sink: sink, gateway: gateway).speak("Say something here.", style: fastSkipping)
    }
    while !gateway.asked { await Task.yield() }
    speaking.cancel()
    await #expect(throws: CancellationError.self) { try await speaking.value }
    #expect(transport.requests.isEmpty)
    #expect(sink.chunks.isEmpty)
  }

  @Test("an ask stopped while the gateway answers plays nothing and makes no TTS request")
  func cancelledAsAnswerLands() async {
    await expectStoppedAsGatewayAnswers { speaker in
      try await speaker.answer("Explain.", about: "x", style: .standard)
    }
  }

  @Test("a rewrite that answers after the stop still plays nothing and makes no TTS request")
  func cancelledAsRewriteLands() async {
    await expectStoppedAsGatewayAnswers { [fastSkipping] speaker in
      try await speaker.speak("Say something here.", style: fastSkipping)
    }
  }

  /// Starts a read or answer whose gateway call answers only after the stop,
  /// stops it mid-call, and checks it throws a cancellation and plays nothing.
  private func expectStoppedAsGatewayAnswers(
    _ start: @escaping @Sendable (SelectionSpeaker) async throws -> Void
  ) async {
    let sink = RecordingSink()
    let transport = FakeSpeechTransport()
    let gateway = LateAnsweringTransport()
    let speaker = SelectionSpeaker(
      synthesizer: AssemblyAISpeechSynthesizer(apiKeyProvider: { "k" }, transport: transport),
      llm: ReadAloudLLM(apiKeyProvider: { "k" }, transport: gateway)
    ) { _ in sink }
    let task = Task { try await start(speaker) }
    while !gateway.asked { await Task.yield() }
    task.cancel()
    gateway.release()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(transport.requests.isEmpty)
    #expect(sink.chunks.isEmpty)
  }
}

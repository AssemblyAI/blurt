import Foundation
import Testing

@testable import BlurtEngine

@Suite("AssemblyAISpeechSynthesizer wire format")
struct AssemblyAISpeechSynthesizerTests {
  private func frame(_ json: String) -> AssemblyAISpeechSynthesizer.Frame {
    AssemblyAISpeechSynthesizer.frame(from: Data(json.utf8))
  }

  @Test("connects to the streaming host with voice and sample rate as query params")
  func url() {
    #expect(
      AssemblyAISpeechSynthesizer.url.absoluteString
        == "wss://streaming-tts.assemblyai.com/v1/ws/?voice=jane&sample_rate=24000")
  }

  @Test("commands are the service's Generate / Flush / Terminate frames")
  func commands() {
    #expect(AssemblyAISpeechSynthesizer.command("Generate", text: "Hi.") == #"{"text":"Hi.","type":"Generate"}"#)
    #expect(AssemblyAISpeechSynthesizer.command("Flush") == #"{"type":"Flush"}"#)
  }

  @Test("Audio frames decode their base64 PCM")
  func audio() {
    let pcm = Data([0x01, 0x00, 0xFF, 0x7F])
    #expect(frame(#"{"type":"Audio","audio":"\#(pcm.base64EncodedString())"}"#) == .audio(pcm))
  }

  @Test("FlushDone is the per-segment acknowledgement")
  func flushDone() {
    #expect(frame(#"{"type":"FlushDone"}"#) == .flushDone)
  }

  @Test("Error frames carry their code, numeric or string")
  func errors() {
    #expect(
      frame(#"{"type":"Error","error_code":1008,"error":"Unauthorized: Invalid API key"}"#)
        == .error("(1008) Unauthorized: Invalid API key"))
    #expect(frame(#"{"type":"Error","error_code":"x","error":" "}"#) == .error("(x) unknown error"))
    #expect(frame(#"{"type":"Error"}"#) == .error("unknown error"))
  }

  @Test("everything else — Begin, WordBoundaries, junk — is ignored, not fatal")
  func ignored() {
    #expect(frame(#"{"type":"Begin"}"#) == .ignored)
    #expect(frame(#"{"type":"WordBoundaries","words":[]}"#) == .ignored)
    #expect(frame(#"{"type":"Audio"}"#) == .ignored)
    #expect(frame("not json") == .ignored)
    #expect(frame("[1]") == .ignored)
  }

  @Test("string and binary socket messages decode the same way")
  func messages() {
    #expect(AssemblyAISpeechSynthesizer.frame(from: .string(#"{"type":"FlushDone"}"#)) == .flushDone)
    #expect(AssemblyAISpeechSynthesizer.frame(from: .data(Data(#"{"type":"FlushDone"}"#.utf8))) == .flushDone)
  }

  @Test("a missing key fails before any socket opens")
  func missingKey() async {
    let synth = AssemblyAISpeechSynthesizer(apiKeyProvider: { nil })
    await #expect(throws: BlurtError.self) {
      for try await _ in synth.synthesize("Hello there.") {}
    }
  }

  @Test("blank text finishes immediately with no audio")
  func blankText() async throws {
    let synth = AssemblyAISpeechSynthesizer(apiKeyProvider: { nil })
    var chunks = 0
    for try await _ in synth.synthesize("   ") { chunks += 1 }
    #expect(chunks == 0)
  }
}

@Suite("AssemblyAISpeechSynthesizer exchange")
struct AssemblyAISpeechSynthesizerExchangeTests {
  private let twoSentences = "The first sentence here. And the second one."

  private func synthesizer(
    _ socket: FakeSpeechSocket, key: String? = "raw-key", request: ValueBox<URLRequest?> = ValueBox(nil)
  ) -> AssemblyAISpeechSynthesizer {
    AssemblyAISpeechSynthesizer(
      apiKeyProvider: { key },
      connect: { sent in
        request.value = sent
        return socket
      })
  }

  @Test("flushes each segment, streams audio in order, and terminates once every flush is acked")
  func happyPath() async throws {
    let socket = FakeSpeechSocket(respond: FakeSpeechSocket.service())
    let request = ValueBox<URLRequest?>(nil)
    var chunks: [Data] = []
    for try await chunk in synthesizer(socket, request: request).synthesize(twoSentences) {
      chunks.append(chunk)
    }
    #expect(chunks == [Data([1, 0]), Data([2, 0])])
    #expect(
      socket.sent == [
        #"{"text":"The first sentence here.","type":"Generate"}"#, #"{"type":"Flush"}"#,
        #"{"text":"And the second one.","type":"Generate"}"#, #"{"type":"Flush"}"#,
        #"{"type":"Terminate"}"#,
      ])
    #expect(socket.closedNormally == true)
    let sent = try #require(request.value)
    // The raw key — `Bearer <key>` upgrades fine and is then refused in-band.
    #expect(sent.value(forHTTPHeaderField: "Authorization") == "raw-key")
    #expect(sent.url == AssemblyAISpeechSynthesizer.url)
  }

  @Test("an in-band Error frame fails the stream and releases the socket")
  func serverError() async {
    let socket = FakeSpeechSocket { _ in
      [#"{"type":"Error","error_code":1008,"error":"Unauthorized: Invalid API key"}"#]
    }
    await #expect(throws: SpeechSynthesisError.server("(1008) Unauthorized: Invalid API key")) {
      for try await _ in synthesizer(socket).synthesize(twoSentences) {}
    }
    #expect(socket.closedNormally == false)
  }

  @Test("a connection dropped mid-exchange fails the stream instead of hanging")
  func dropped() async {
    let socket = FakeSpeechSocket(respond: { _ in [] })
    await #expect(throws: URLError.self) {
      let stream = synthesizer(socket).synthesize(twoSentences)
      socket.drop()
      for try await _ in stream {}
    }
    #expect(socket.closedNormally == false)
  }

  @Test("a server that goes silent times out and releases the socket")
  func silentServer() async {
    let socket = FakeSpeechSocket(respond: { _ in [] })
    let synth = AssemblyAISpeechSynthesizer(
      apiKeyProvider: { "k" }, receiveTimeout: .milliseconds(50), connect: { _ in socket })
    await #expect(throws: SpeechSynthesisError.timedOut) {
      for try await _ in synth.synthesize("Say something here.") {}
    }
    #expect(socket.closedNormally == false)
  }

  @Test("Begin, WordBoundaries and empty audio don't count as audio or acks")
  func noise() async throws {
    let socket = FakeSpeechSocket { command in
      guard command.contains(#""Flush""#) else { return [#"{"type":"Begin"}"#] }
      return [
        #"{"type":"Audio","audio":""}"#, #"{"type":"WordBoundaries"}"#,
        FakeSpeechSocket.audio([9, 9]), FakeSpeechSocket.flushDone,
      ]
    }
    var chunks: [Data] = []
    for try await chunk in synthesizer(socket).synthesize("Just one sentence.") { chunks.append(chunk) }
    #expect(chunks == [Data([9, 9])])
  }

  @Test("cancelling the consumer closes the socket abruptly")
  func cancellation() async throws {
    let socket = FakeSpeechSocket(respond: { _ in [] })
    let synth = synthesizer(socket)
    let consumer = Task {
      for try await _ in synth.synthesize(twoSentences) {}
    }
    while socket.sent.isEmpty { await Task.yield() }
    consumer.cancel()
    _ = await consumer.result
    while socket.closedNormally == nil { await Task.yield() }
    #expect(socket.closedNormally == false)
  }
}

@Suite("SelectionSpeaker")
struct SelectionSpeakerTests {
  private func speaker(_ socket: FakeSpeechSocket, sink: RecordingSink) -> SelectionSpeaker {
    SelectionSpeaker(
      synthesizer: AssemblyAISpeechSynthesizer(apiKeyProvider: { "k" }, connect: { _ in socket }),
      makeSink: { sink })
  }

  @Test("plays every chunk in order, then drains")
  func plays() async throws {
    let sink = RecordingSink()
    try await speaker(FakeSpeechSocket(respond: FakeSpeechSocket.service()), sink: sink)
      .speak("The first sentence here. And the second one.")
    #expect(sink.chunks == [Data([1, 0]), Data([2, 0])])
    #expect(sink.drained)
  }

  @Test("a synthesis failure silences playback and surfaces the error")
  func failure() async {
    let sink = RecordingSink()
    let socket = FakeSpeechSocket { _ in [#"{"type":"Error","error":"boom"}"#] }
    await #expect(throws: SpeechSynthesisError.server("boom")) {
      try await speaker(socket, sink: sink).speak("Say something here.")
    }
    #expect(sink.stopped)
    #expect(!sink.drained)
  }

  @Test("cancelling the speaking task stops playback")
  func cancellation() async {
    let sink = RecordingSink()
    let socket = FakeSpeechSocket(respond: { _ in [] })
    let speaking = Task { try await speaker(socket, sink: sink).speak("Say something here.") }
    while socket.sent.isEmpty { await Task.yield() }
    speaking.cancel()
    _ = await speaking.result
    #expect(sink.stopped)
  }
}

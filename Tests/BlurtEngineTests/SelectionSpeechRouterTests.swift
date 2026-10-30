import Foundation
import Testing

@testable import AssemblyAI
@testable import BlurtEngine

/// The router that carries out `SelectionSpeechRouting`'s decisions: the
/// selection read, the speech task, and the start/end the pill and cues follow.
@MainActor
@Suite("SelectionSpeechRouter")
struct SelectionSpeechRouterTests {
  private let defaults = freshDefaults()

  private func router(
    _ transport: FakeSpeechTransport, selection: String?, rate: ValueBox<Double?> = ValueBox(nil)
  ) -> (SelectionSpeechRouter, SessionFixture) {
    // Verbatim reads, so no gateway call shapes what's spoken.
    defaults.set(false, forKey: ReadAloudStyleStore.skipsJargonDefaultsKey)
    let fixture = makeSession()
    let speaker = SelectionSpeaker(
      synthesizer: AssemblyAISpeechSynthesizer(apiKeyProvider: { "k" }, transport: transport),
      llm: ReadAloudLLM(apiKeyProvider: { "k" }, transport: FakeHTTPTransport.failing(with: URLError(.timedOut))),
      makeSink: { played in
        rate.value = played
        return RecordingSink()
      })
    let router = SelectionSpeechRouter(
      session: fixture.session, speaker: speaker, readSelection: { selection }, defaults: defaults)
    return (router, fixture)
  }

  @Test("a tap of left ⌥ over a selection reads it, between one start and one end")
  func tapReadsSelection() async throws {
    let transport = FakeSpeechTransport()
    let (router, _) = router(transport, selection: "Hello there.")
    var events: [String] = []
    router.speechStarted = { events.append("start") }
    router.speechEnded = { events.append("end") }
    router.press(key: .leftOption)
    router.keyLatched()
    try await waitUntil { events.count == 2 }
    #expect(events == ["start", "end"])
    #expect(transport.spoken == ["Hello there."])
  }

  @Test("with nothing selected, left ⌥ reads nothing and clears the gate")
  func nothingSelected() async throws {
    let transport = FakeSpeechTransport()
    let (router, _) = router(transport, selection: nil)
    var resets = 0
    var started = false
    router.resetGate = { resets += 1 }
    router.speechStarted = { started = true }
    router.press(key: .leftOption)
    try await waitUntil { resets == 1 }
    #expect(!started)
    #expect(transport.requests.isEmpty)
  }

  @Test("a failed read reports the failure and still ends")
  func failureReported() async throws {
    let transport = FakeSpeechTransport { _ in (500, [Data(#"{"message":"boom"}"#.utf8)]) }
    let (router, _) = router(transport, selection: "Hello there.")
    var failures: [String] = []
    var ended = false
    router.speechFailed = { failures.append(($0 as? SpeechSynthesisError)?.errorDescription ?? "") }
    router.speechEnded = { ended = true }
    router.press(key: .leftOption)
    router.keyLatched()
    try await waitUntil { ended }
    #expect(failures == ["Text-to-speech failed: boom"])
  }

  @Test("a sample plays in the picked voice at the picked speed")
  func sampleUsesPickedStyle() async throws {
    let transport = FakeSpeechTransport()
    let rate = ValueBox<Double?>(nil)
    let (router, _) = router(transport, selection: nil, rate: rate)
    defaults.set(2.0, forKey: ReadAloudStyleStore.speedDefaultsKey)
    defaults.set("aai-buford", forKey: ReadAloudStyleStore.voiceDefaultsKey)
    router.previewSample()
    try await waitUntil { !transport.requests.isEmpty }
    #expect(rate.value == 2)
    let body = transport.requests.first?.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) }
    #expect((body as? [String: Any])?["voice_id"] as? String == "aai-buford")
    #expect(transport.spoken.first?.hasPrefix("Hi, I'm Buford.") == true)
  }
}

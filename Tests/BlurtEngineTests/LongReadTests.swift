import Foundation
import Synchronization
import Testing

@testable import AssemblyAI
@testable import BlurtEngine

/// Long articles: reading starts after the first sentence, text goes to the
/// service only as fast as it's listened to, and skip-jargon rewrites one chunk
/// at a time instead of the whole article up front.
@Suite("Long reads")
struct LongReadTests {
  /// An article of `paragraphs` paragraphs, each a dozen sentences long.
  private func article(paragraphs: Int) -> String {
    (1...paragraphs).map { index in
      (1...12).map { "Paragraph \(index) sentence \($0) runs on a little." }.joined(separator: " ")
    }
    .joined(separator: "\n\n")
  }

  private func speaker(
    _ transport: FakeSpeechTransport, sink: RecordingSink,
    gateway: any HTTPTransport = FakeHTTPTransport.failing(
      with: URLError(.notConnectedToInternet))
  ) -> SelectionSpeaker {
    SelectionSpeaker(
      synthesizer: AssemblyAISpeechSynthesizer(apiKeyProvider: { "k" }, transport: transport),
      llm: ReadAloudLLM(apiKeyProvider: { "k" }, transport: gateway),
      makeSink: { _ in sink })
  }

  @Test("selections up to 100,000 characters are read, so a long article isn't cut off")
  func raisedCap() {
    #expect(SelectionSpeaker.maxCharacters == 100_000)
  }

  @Test("the next piece is asked for only once little audio is queued ahead")
  func pacesByPlayback() async throws {
    let transport = FakeSpeechTransport()
    let sink = RecordingSink()
    let text = article(paragraphs: 4)
    let pieces = ListeningChunks.chunks(of: text)
    #expect(pieces.count > 2)
    // The first piece's audio leaves a minute waiting to be heard.
    sink.bufferedAfterEnqueue = 60
    let reading = Task { try await speaker(transport, sink: sink).speak(text) }
    try await Task.sleep(for: .milliseconds(600))
    #expect(transport.spoken == [pieces[0]], "a piece went out while a minute was still queued")
    // The listener catches up.
    sink.bufferedAfterEnqueue = nil
    sink.bufferedSeconds = 0
    try await reading.value
    #expect(transport.spoken == pieces)
  }

  @Test("the first piece is short, so reading starts after a paragraph, not the article")
  func shortFirstPiece() {
    let pieces = ListeningChunks.chunks(of: article(paragraphs: 6))
    #expect(pieces[0].count <= ListeningChunks.firstMaxCharacters)
    #expect(pieces.dropFirst().allSatisfy { $0.count <= ListeningChunks.maxCharacters })
  }

  @Test("skip-jargon rewrites a long article a piece at a time, and reading starts after the first")
  func rewritesInPieces() async throws {
    let text = article(paragraphs: 6)
    let pieces = ListeningChunks.chunks(of: text)
    let gateway = GatedRewrites()
    let transport = FakeSpeechTransport()
    let sink = RecordingSink()
    let reading = Task {
      try await speaker(transport, sink: sink, gateway: gateway)
        .speak(text, style: ReadAloudStyle(rate: 1, skipsJargon: true))
    }
    // Only the first piece's rewrite is answered, and it's already being read.
    gateway.release(1)
    while transport.spoken.isEmpty { await Task.yield() }
    for _ in 0..<200 { await Task.yield() }
    #expect(transport.spoken == ["Rewritten 1. The words read aloud."])
    #expect(gateway.asked <= 2, "the whole article went to the gateway before reading")
    gateway.release(.max)
    try await reading.value
    #expect(transport.spoken.count == pieces.count)
    #expect(gateway.asked == pieces.count)
  }

  @Test("pieces break at paragraphs, each within its limit, losing no text")
  func chunks() {
    let paragraph = String(repeating: "Some words in a sentence. ", count: 20)
    let text = Array(repeating: paragraph.trimmingCharacters(in: .whitespaces), count: 5).joined(separator: "\n\n")
    let chunks = ListeningChunks.chunks(of: text, maxCharacters: 1_200, firstMaxCharacters: 1_200)
    #expect(chunks.count > 1)
    #expect(chunks.allSatisfy { $0.count <= 1_200 })
    #expect(
      chunks.joined(separator: " ").split(whereSeparator: \.isWhitespace)
        == text.split(whereSeparator: \.isWhitespace))
    #expect(ListeningChunks.chunks(of: "Short.") == ["Short."])
    #expect(ListeningChunks.chunks(of: "  \n\n ").isEmpty)
  }
}

/// A gateway answering rewrite requests only as the test releases them, each
/// answer naming its request: "Rewritten 1.", "Rewritten 2.", …
private final class GatedRewrites: GatewayStub, Sendable {
  private let state = Mutex((asked: 0, released: 0))

  var asked: Int { state.withLock(\.asked) }

  func release(_ count: Int) {
    state.withLock { $0.released = count == .max ? .max : $0.released + count }
  }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    let number = state.withLock { state -> Int in
      state.asked += 1
      return state.asked
    }
    while state.withLock({ $0.released < number }) {
      try await Task.sleep(for: .milliseconds(5))
    }
    return try ok(request, completion("Rewritten \(number). The words read aloud."))
  }
}

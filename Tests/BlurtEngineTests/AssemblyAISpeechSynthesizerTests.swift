import Foundation
import Testing

@testable import AssemblyAI
@testable import BlurtEngine

@Suite("AssemblyAISpeechSynthesizer")
struct AssemblyAISpeechSynthesizerTests {
  private func synthesizer(_ transport: FakeSpeechTransport, key: String? = "raw-key") -> AssemblyAISpeechSynthesizer {
    AssemblyAISpeechSynthesizer(apiKeyProvider: { key }, transport: transport)
  }

  private func body(_ request: URLRequest) throws -> [String: Any] {
    let data = try #require(request.httpBody)
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  @Test("posts the documented JSON to the US host's /v1/speech, with the raw key")
  func request() throws {
    let request = try AssemblyAISpeechSynthesizer.request(for: "Hi there.", voiceID: "aai-sara", apiKey: "raw-key")
    #expect(request.url?.absoluteString == "https://tts.us.assemblyai.com/v1/speech")
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "raw-key")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    #expect(request.timeoutInterval == AssemblyAISpeechSynthesizer.timeout)
    let fields = try body(request)
    #expect(fields["text"] as? String == "Hi there.")
    #expect(fields["voice_id"] as? String == "aai-sara")
    #expect(fields["sample_rate"] as? Int == 24_000)
    #expect(fields["encoding"] as? String == "pcm_s16le")
    // Nothing undocumented, and not the retired bare `voice`.
    #expect(Set(fields.keys) == ["text", "voice_id", "sample_rate", "encoding"])
  }

  @Test("streams the response body's audio in order")
  func streams() async throws {
    let transport = FakeSpeechTransport { _ in (200, [Data([1, 0, 2, 0]), Data([3, 0])]) }
    var chunks: [Data] = []
    for try await chunk in synthesizer(transport).speech(for: "Read this.", voiceID: "aai-titus") {
      chunks.append(chunk)
    }
    #expect(chunks == [Data([1, 0, 2, 0]), Data([3, 0])])
    #expect(transport.spoken == ["Read this."])
    #expect(try body(#require(transport.requests.first))["voice_id"] as? String == "aai-titus")
  }

  @Test("a sample split across network reads is carried over whole")
  func carriesOddBytes() async throws {
    let transport = FakeSpeechTransport { _ in (200, [Data([1]), Data([0, 2, 0, 3]), Data([0])]) }
    var audio = Data()
    for try await chunk in synthesizer(transport).speech(for: "Read this.") {
      #expect(chunk.count % 2 == 0)
      audio.append(chunk)
    }
    #expect(audio == Data([1, 0, 2, 0, 3, 0]))
  }

  @Test("a failed request reports the body's code and message, or the bare status")
  func failures() async {
    let refused = FakeSpeechTransport { _ in
      (401, [Data(#"{"code":"unauthorized","message":"Invalid API key"}"#.utf8)])
    }
    await #expect(throws: SpeechSynthesisError.server("(unauthorized) Invalid API key")) {
      for try await _ in synthesizer(refused).speech(for: "Read this.") {}
    }
    #expect(AssemblyAISpeechSynthesizer.failure(status: 502, body: Data("<html>".utf8)) == "HTTP 502")
  }

  @Test("a missing key fails before any request, and blank text makes none")
  func noRequest() async throws {
    let transport = FakeSpeechTransport()
    await #expect(throws: BlurtError.self) {
      for try await _ in synthesizer(transport, key: nil).speech(for: "Hello there.") {}
    }
    var chunks = 0
    for try await _ in synthesizer(transport).speech(for: "   ") { chunks += 1 }
    #expect(chunks == 0)
    #expect(transport.requests.isEmpty)
  }
}

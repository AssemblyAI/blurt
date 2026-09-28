import Foundation
import Testing

@testable import BlurtEngine

@Suite("OpenRouterTextNormalizer wire format")
struct OpenRouterTextNormalizerTests {
  @Test("encodes model, deterministic temperature, vocabulary and Russian transcript")
  func requestEncoding() async throws {
    let response = """
      {"choices":[{"message":{"role":"assistant","content":"Готово."}}]}
      """.data(using: .utf8) ?? Data()
    let captured = ValueBox<URLRequest?>(nil)
    let transport = FakeHTTPTransport { request in
      captured.value = request
      return (200, response)
    }
    let normalizer = OpenRouterTextNormalizer(
      apiKeyProvider: { "secret" }, modelProvider: { "test/model" }, transport: transport)

    let result = try await normalizer.normalize(
      rawTranscript: "напиши на Swift", vocabulary: ["Swift", "OpenAI"])

    #expect(result == "Готово.")
    let request = try #require(captured.value)
    let body = try #require(request.httpBody)
    let decoded = try JSONDecoder().decode(OpenRouterTextNormalizer.Request.self, from: body)
    #expect(decoded.model == "test/model")
    #expect(decoded.temperature == 0)
    #expect(decoded.messages.last?.content.contains("Swift, OpenAI") == true)
    #expect(decoded.messages.last?.content.contains("напиши на Swift") == true)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
  }

  @Test("decodes OpenRouter chat completion")
  func responseDecoding() throws {
    let data = """
      {"choices":[{"message":{"role":"assistant","content":"Текст."}}]}
      """.data(using: .utf8) ?? Data()
    let decoded = try JSONDecoder().decode(OpenRouterTextNormalizer.Response.self, from: data)
    #expect(decoded.choices.first?.message.content == "Текст.")
  }

  @Test("missing key, rejected request and blank response all fail for fallback")
  func fallbackErrors() async {
    let missing = OpenRouterTextNormalizer(apiKeyProvider: { nil })
    await #expect(throws: OpenRouterError.missingAPIKey) {
      try await missing.normalize(rawTranscript: "raw", vocabulary: [])
    }
    let rejected = OpenRouterTextNormalizer(
      apiKeyProvider: { "key" }, transport: FakeHTTPTransport { _ in (429, Data()) })
    await #expect(throws: OpenRouterError.httpStatus(429)) {
      try await rejected.normalize(rawTranscript: "raw", vocabulary: [])
    }
    let blank = OpenRouterTextNormalizer(
      apiKeyProvider: { "key" },
      transport: FakeHTTPTransport { _ in
        (200, #"{"choices":[{"message":{"role":"assistant","content":"   "}}]}"#.data(using: .utf8)!)
      })
    await #expect(throws: OpenRouterError.malformedResponse) {
      try await blank.normalize(rawTranscript: "raw", vocabulary: [])
    }
  }
}

import Foundation
import Testing

@testable import BlurtEngine

// The `APIKeyValidator` half of the `HTTPClientTests` suite. Kept on the same
// suite type (see `HTTPClientTests`' doc comment in `AssemblyAITranscriberTests.swift`)
// so it shares that suite's `.serialized` ordering around the process-global
// `MockURLProtocol.responder`.
extension HTTPClientTests {

  @Test("validator returns .valid on a 2xx response with the key in Authorization")
  func validateValidKey() async {
    MockURLProtocol.responder = { request in
      guard request.url?.path.hasSuffix("/v2/transcript") == true,
        request.url?.query?.contains("limit=1") == true,
        request.value(forHTTPHeaderField: "Authorization") == "good-key"
      else { return (404, Data()) }
      return (200, json(["page_number": "1"]))
    }
    defer { MockURLProtocol.responder = nil }

    #expect(await makeValidator().validate("good-key") == .valid)
  }

  @Test("validator returns .invalid when AssemblyAI rejects the key")
  func validateInvalidKey() async {
    MockURLProtocol.responder = { _ in (401, json(["error": "Invalid API key"])) }
    defer { MockURLProtocol.responder = nil }

    #expect(await makeValidator().validate("bad-key") == .invalid)
  }

  @Test("validator returns .unreachable on an unexpected status (offline-safe)")
  func validateUnreachable() async {
    MockURLProtocol.responder = { _ in (500, Data()) }
    defer { MockURLProtocol.responder = nil }

    #expect(await makeValidator().validate("any-key") == .unreachable)
  }

  @Test("validator treats a 4xx client error (other than 408/429) as invalid")
  func validateClientErrorIsInvalid() async {
    MockURLProtocol.responder = { _ in (400, json(["error": "bad request"])) }
    defer { MockURLProtocol.responder = nil }

    #expect(await makeValidator().validate("malformed-key") == .invalid)
  }

  @Test("validator treats 429 rate-limit as unreachable, not invalid")
  func validateRateLimitedIsUnreachable() async {
    MockURLProtocol.responder = { _ in (429, json(["error": "rate limited"])) }
    defer { MockURLProtocol.responder = nil }

    // A good key that happens to be rate-limited during setup must not be
    // rejected — saving anyway is the offline-safe choice for a transient state.
    #expect(await makeValidator().validate("good-key") == .unreachable)
  }

  @Test("validator treats blank input as invalid without making a request")
  func validateBlank() async {
    let hits = Counter()
    MockURLProtocol.responder = { _ in
      _ = hits.next()
      return (200, Data())
    }
    defer { MockURLProtocol.responder = nil }

    #expect(await makeValidator().validate("   ") == .invalid)
    #expect(hits.value == 0)
  }

  // MARK: - helpers

  private func makeValidator() -> APIKeyValidator {
    APIKeyValidator(baseURL: URL(string: "https://api.assemblyai.com")!, urlSession: mockURLSession())
  }
}

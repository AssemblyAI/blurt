import Foundation
import Testing

@testable import BlurtEngine

// The `APIKeyValidator` half of the `HTTPClientTests` suite. Kept on the same
// suite type so it shares the `makeTranscriber`/`makeValidator` helpers and the
// `FakeHTTPTransport` seam; each test wires its own per-instance transport, so
// there is no shared state and no `.serialized` ordering.
extension HTTPClientTests {

  @Test("validator returns .valid on a 2xx response with the key in Authorization")
  func validateValidKey() async {
    let transport = FakeHTTPTransport { request in
      guard request.url?.path.hasSuffix("/v2/transcript") == true,
        request.url?.query?.contains("limit=1") == true,
        request.value(forHTTPHeaderField: "Authorization") == "good-key"
      else { return (404, Data()) }
      return (200, json(["page_number": "1"]))
    }

    #expect(await makeValidator(transport).validate("good-key") == .valid)
  }

  @Test("validator returns .invalid when AssemblyAI rejects the key")
  func validateInvalidKey() async {
    let transport = FakeHTTPTransport { _ in (401, json(["error": "Invalid API key"])) }
    #expect(await makeValidator(transport).validate("bad-key") == .invalid)
  }

  @Test("validator returns .unreachable on an unexpected status (offline-safe)")
  func validateUnreachable() async {
    let transport = FakeHTTPTransport { _ in (500, Data()) }
    #expect(await makeValidator(transport).validate("any-key") == .unreachable)
  }

  @Test("validator treats a 4xx client error (other than 408/429) as invalid")
  func validateClientErrorIsInvalid() async {
    let transport = FakeHTTPTransport { _ in (400, json(["error": "bad request"])) }
    #expect(await makeValidator(transport).validate("malformed-key") == .invalid)
  }

  @Test("validator treats 429 rate-limit as unreachable, not invalid")
  func validateRateLimitedIsUnreachable() async {
    let transport = FakeHTTPTransport { _ in (429, json(["error": "rate limited"])) }
    // A good key that happens to be rate-limited during setup must not be
    // rejected — saving anyway is the offline-safe choice for a transient state.
    #expect(await makeValidator(transport).validate("good-key") == .unreachable)
  }

  @Test("validator treats a 408 timeout as unreachable, not invalid")
  func validateTimeoutIsUnreachable() async {
    let transport = FakeHTTPTransport { _ in (408, json(["error": "request timeout"])) }
    // The other transient 4xx: like 429, it says nothing about the key itself.
    #expect(await makeValidator(transport).validate("good-key") == .unreachable)
  }

  @Test("validator treats an unexpected non-4xx status (e.g. a redirect) as unreachable")
  func validateUnexpectedStatusIsUnreachable() async {
    let transport = FakeHTTPTransport { _ in (301, Data()) }
    #expect(await makeValidator(transport).validate("good-key") == .unreachable)
  }

  @Test("validator returns .unreachable when the request fails in transport (offline)")
  func validateTransportFailureIsUnreachable() async {
    // The reason .unreachable exists: no HTTP response at all (offline, DNS
    // failure) must read as "retry when online", never as a rejected key.
    let transport = FakeHTTPTransport.failing(with: URLError(.notConnectedToInternet))
    #expect(await makeValidator(transport).validate("good-key") == .unreachable)
  }

  @Test("validator treats blank input as invalid without making a request")
  func validateBlank() async {
    let hits = Counter()
    let transport = FakeHTTPTransport { _ in
      _ = hits.next()
      return (200, Data())
    }

    #expect(await makeValidator(transport).validate("   ") == .invalid)
    #expect(hits.value == 0)
  }

  // MARK: - helpers

  private func makeValidator(_ transport: any HTTPTransport) -> APIKeyValidator {
    APIKeyValidator(transport: transport)
  }
}

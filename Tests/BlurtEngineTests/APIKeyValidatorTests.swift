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

  @Test("validator treats a 400 malformed-request as invalid")
  func validateClientErrorIsInvalid() async {
    let transport = FakeHTTPTransport { _ in (400, json(["error": "bad request"])) }
    #expect(await makeValidator(transport).validate("malformed-key") == .invalid)
  }

  @Test("a 4xx that says nothing about the key is unreachable, not invalid")
  func validateEndpointErrorIsUnreachable() async {
    // `.invalid` hard-blocks setup: `APIKeySubmission` refuses to persist, so the
    // user can't finish onboarding. Only statuses that actually mean "credential
    // rejected" or "malformed key" may report it. A 404/405/410 (endpoint retired
    // or moved) or a proxy/captive-portal 403-page equivalent says nothing about
    // the key, so it must fall through to the retry-later outcome — a blanket
    // `400..<500 -> .invalid` told users their working key was rejected.
    for status in [404, 405, 410, 451] {
      let transport = FakeHTTPTransport { _ in (status, json(["error": "not here"])) }
      #expect(
        await makeValidator(transport).validate("good-key") == .unreachable,
        "status \(status) must not reject the key")
    }
  }

  @Test("the rest of the credential-rejecting statuses also report .invalid")
  func validateRemainingRejectingStatuses() async {
    // 401 and 400 have cases of their own above; these two were the members of the
    // `.invalid` list with no test at all, so dropping either from it would have
    // gone unnoticed — and the failure is a *misleading* one rather than a loud
    // one. On `.unreachable` the sheet says "Couldn't reach AssemblyAI. Check your
    // connection and try again" (`Outcome.failureReport`), sending the user to
    // debug a connection that is working fine, about a key AssemblyAI actually
    // rejected.
    //
    // 403 is a verdict on the credential: AssemblyAI answers an authenticated
    // request it won't serve with it. 422 means the key itself is malformed.
    for status in [403, 422] {
      let transport = FakeHTTPTransport { _ in (status, json(["error": "rejected"])) }
      #expect(
        await makeValidator(transport).validate("bad-key") == .invalid,
        "status \(status) must reject the key")
    }
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

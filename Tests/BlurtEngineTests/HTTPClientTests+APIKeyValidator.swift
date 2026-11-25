import Foundation
import Synchronization
import Testing

@testable import AssemblyAI
@testable import BlurtAssemblyAI
@testable import BlurtEngine

// The `APIKeyValidator` half of the `HTTPClientTests` suite. Kept on the same
// suite type so it shares the `makeTranscriber`/`makeValidator` helpers and the
// `FakeHTTPTransport` seam; each test wires its own per-instance transport, so
// there is no shared state and no `.serialized` ordering.
extension HTTPClientTests {
  /// One HTTP status AssemblyAI might answer the key check with, and the verdict
  /// it must produce. `.invalid` hard-blocks setup — `APIKeySubmission` refuses to
  /// persist, so the user can't finish onboarding — so only statuses that actually
  /// mean "credential rejected" or "malformed key" may report it; everything else
  /// falls through to the retry-later `.unreachable`.
  struct StatusCase: Sendable, CustomTestStringConvertible {
    let name: String
    let status: Int
    let body: Data
    let expected: APIKeyValidator.Result
    var testDescription: String { "\(status): \(name)" }

    init(_ name: String, _ status: Int, _ expected: APIKeyValidator.Result, body: Data = Data()) {
      self.name = name
      self.status = status
      self.body = body
      self.expected = expected
    }
  }

  static let statusCases: [StatusCase] = [
    StatusCase("AssemblyAI rejects the key", 401, .invalid, body: json(["error": "Invalid API key"])),
    StatusCase("a malformed request is invalid", 400, .invalid, body: json(["error": "bad request"])),
    // 401 and 400 were long the only `.invalid` statuses under test, so dropping
    // 403 or 422 from the list would have gone unnoticed — and the failure is a
    // *misleading* one rather than a loud one. On `.unreachable` the sheet says
    // "Couldn't reach AssemblyAI. Check your connection and try again"
    // (`Outcome.failureReport`), sending the user to debug a connection that is
    // working fine, about a key AssemblyAI actually rejected.
    //
    // 403 is a verdict on the credential: AssemblyAI answers an authenticated
    // request it won't serve with it. 422 means the key itself is malformed.
    StatusCase("a forbidden credential is invalid", 403, .invalid, body: json(["error": "rejected"])),
    StatusCase("a malformed key is invalid", 422, .invalid, body: json(["error": "rejected"])),
    StatusCase("an unexpected server error is unreachable (offline-safe)", 500, .unreachable),
    // A 404/405/410 (endpoint retired or moved) or a proxy/captive-portal 403-page
    // equivalent says nothing about the key, so it must fall through to the
    // retry-later outcome — a blanket `400..<500 -> .invalid` told users their
    // working key was rejected.
    StatusCase("a retired endpoint says nothing about the key", 404, .unreachable, body: json(["error": "not here"])),
    StatusCase("a moved endpoint says nothing about the key", 405, .unreachable, body: json(["error": "not here"])),
    StatusCase("a gone endpoint says nothing about the key", 410, .unreachable, body: json(["error": "not here"])),
    StatusCase(
      "a proxy's blocked-request page says nothing about the key",
      451,
      .unreachable,
      body: json(["error": "not here"])
    ),
    // A good key that happens to be rate-limited during setup must not be
    // rejected — saving anyway is the offline-safe choice for a transient state.
    StatusCase("a rate limit is unreachable, not invalid", 429, .unreachable, body: json(["error": "rate limited"])),
    // The other transient 4xx: like 429, it says nothing about the key itself.
    StatusCase("a timeout is unreachable, not invalid", 408, .unreachable, body: json(["error": "request timeout"])),
    StatusCase("an unexpected non-4xx status (a redirect) is unreachable", 301, .unreachable),
  ]

  @Test("validator returns .valid on a 2xx response with the key and agent in the headers")
  func validateValidKey() async {
    let transport = FakeHTTPTransport { request in
      guard request.url?.path.hasSuffix("/v2/transcript") == true,
        request.url?.query?.contains("limit=1") == true,
        request.value(forHTTPHeaderField: "Authorization") == "good-key",
        // The same agent the dictation requests carry — the wizard's key check
        // is a Blurt request too, and nothing about it should look unattributed.
        request.value(forHTTPHeaderField: "User-Agent") == UserAgent.current
      else {
        return (404, Data())
      }
      return (200, json(["page_number": "1"]))
    }

    #expect(await makeValidator(transport).validate("good-key") == .valid)
  }

  @Test("validator maps each HTTP status to a verdict on the key", arguments: statusCases)
  func validateStatus(_ c: StatusCase) async {
    let transport = FakeHTTPTransport { _ in (c.status, c.body) }
    #expect(await makeValidator(transport).validate("some-key") == c.expected)
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

  @Test("the SDK's validator sends only the agent it's given; Blurt's comes from .blurt()")
  func validatorAgentIsTheCallers() async {
    let agents = Mutex<[String?]>([])
    let transport = FakeHTTPTransport { request in
      agents.withLock { $0.append(request.value(forHTTPHeaderField: "User-Agent")) }
      return (200, json(["page_number": "1"]))
    }
    #expect(await APIKeyValidator(transport: transport).validate("k") == .valid)
    #expect(await APIKeyValidator(transport: transport, userAgent: "MyApp/1.0").validate("k") == .valid)
    #expect(agents.withLock { $0 } == [nil, "MyApp/1.0"])
  }

  // MARK: - helpers

  private func makeValidator(_ transport: any HTTPTransport) -> APIKeyValidator {
    APIKeyValidator.blurt(transport: transport)
  }
}

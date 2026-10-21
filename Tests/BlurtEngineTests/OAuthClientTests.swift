import Foundation
import Testing

@testable import AssemblyAI

/// A configuration on placeholder hosts; nothing here reaches the network.
let testOAuthConfiguration = OAuthConfiguration(
  clientID: "connected-app-test-client",
  authorizeURL: URL(literal: "https://example.com/dashboard/oauth/authorize"),
  tokenURL: URL(literal: "https://auth.example.com/v1/oauth2/token"),
  apiKeyURL: URL(literal: "https://example.com/api/v2/oauth/api-key"),
  revokeURL: URL(literal: "https://example.com/api/v2/oauth/api-key/revoke"),
  redirectURI: URL(literal: "com.assemblyai.blurt://oauth/callback"))

/// An unsigned JWT carrying `claims`, shaped like the ID token the token
/// endpoint returns.
func unsignedJWT(_ claims: [String: String]) -> String {
  let payload = (try? JSONSerialization.data(withJSONObject: claims)) ?? Data()
  return "eyJhbGciOiJub25lIn0.\(OAuthAuthorization.base64URL(Array(payload))).sig"
}

@Suite("OAuth authorization (PKCE)")
struct OAuthAuthorizationTests {
  /// RFC 7636 Appendix B: these 32 octets give this verifier and challenge.
  static let rfcOctets: [UInt8] = [
    116, 24, 223, 180, 151, 153, 224, 37, 79, 250, 96, 125, 216, 173, 187, 186,
    22, 212, 37, 77, 105, 214, 191, 240, 91, 88, 5, 88, 83, 132, 141, 121,
  ]

  private func authorization() -> OAuthAuthorization {
    OAuthAuthorization(configuration: testOAuthConfiguration) { count in Array(Self.rfcOctets.prefix(count)) }
  }

  @Test("the verifier and S256 challenge match RFC 7636's worked example")
  func rfcVector() {
    let auth = authorization()
    #expect(auth.codeVerifier == "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
    #expect(auth.codeChallenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
  }

  @Test("the consent URL carries the client, redirect, scopes, state and challenge")
  func consentURL() throws {
    let auth = authorization()
    let components = try #require(URLComponents(url: auth.url, resolvingAgainstBaseURL: false))
    let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })
    #expect(components.path == "/dashboard/oauth/authorize")
    #expect(query["client_id"] == "connected-app-test-client")
    #expect(query["redirect_uri"] == "com.assemblyai.blurt://oauth/callback")
    #expect(query["response_type"] == "code")
    #expect(query["scope"] == "openid email offline_access aai:api")
    #expect(query["state"] == auth.state)
    #expect(query["code_challenge"] == auth.codeChallenge)
    #expect(query["code_challenge_method"] == "S256")
  }

  @Test("each attempt gets its own verifier and state")
  func freshPerAttempt() {
    let first = OAuthAuthorization(configuration: testOAuthConfiguration)
    let second = OAuthAuthorization(configuration: testOAuthConfiguration)
    #expect(first.codeVerifier != second.codeVerifier)
    #expect(first.state != second.state)
    #expect(first.codeVerifier.count == 43)
  }

  @Test("a callback for this attempt yields its code")
  func callbackCode() throws {
    let auth = authorization()
    let callback = try #require(URL(string: "com.assemblyai.blurt://oauth/callback?code=abc&state=\(auth.state)"))
    #expect(try auth.code(fromCallback: callback) == "abc")
  }

  @Test("a callback is refused on the wrong state, a decline, an error, or no code")
  func callbackRefusals() throws {
    let auth = authorization()
    let state = auth.state
    let cases: [(String, OAuthAuthorization.CallbackError)] = [
      ("code=abc&state=other", .stateMismatch),
      ("code=abc", .stateMismatch),
      ("error=access_denied&state=\(state)", .denied),
      ("error=server_error&error_description=boom&state=\(state)", .failed("boom")),
      ("error=server_error&state=\(state)", .failed("server_error")),
      ("state=\(state)", .failed(nil)),
    ]
    for (query, expected) in cases {
      let callback = try #require(URL(string: "com.assemblyai.blurt://oauth/callback?\(query)"))
      #expect(throws: expected) { try auth.code(fromCallback: callback) }
    }
  }

  @Test("the callback scheme is the redirect's")
  func callbackScheme() {
    #expect(testOAuthConfiguration.callbackScheme == "com.assemblyai.blurt")
  }
}

@Suite("OAuth client")
struct OAuthClientTests {
  private func client(_ transport: FakeHTTPTransport) -> OAuthClient {
    OAuthClient(configuration: testOAuthConfiguration, transport: transport, userAgent: "Blurt/test")
  }

  private static func form(_ request: URLRequest) -> [String: String] {
    let body = String(bytes: request.httpBody ?? Data(), encoding: .utf8) ?? ""
    var fields: [String: String] = [:]
    for pair in body.split(separator: "&") {
      let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
      fields[parts[0]] = parts.count > 1 ? parts[1].removingPercentEncoding : ""
    }
    return fields
  }

  @Test("the code exchange posts the code, verifier and redirect, and reads the tokens")
  func codeExchange() async throws {
    let auth = OAuthAuthorization(configuration: testOAuthConfiguration)
    let idToken = unsignedJWT(["email": "member@example.com"])
    let transport = FakeHTTPTransport { request in
      let form = Self.form(request)
      guard request.url == testOAuthConfiguration.tokenURL, request.httpMethod == "POST",
        request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded",
        request.value(forHTTPHeaderField: "User-Agent") == "Blurt/test",
        form["grant_type"] == "authorization_code", form["code"] == "the-code",
        form["code_verifier"] == auth.codeVerifier, form["client_id"] == "connected-app-test-client",
        form["redirect_uri"] == "com.assemblyai.blurt://oauth/callback"
      else { return (400, Data()) }
      return (200, json(["access_token": "at", "refresh_token": "rt", "id_token": idToken]))
    }
    let tokens = try await client(transport).tokens(for: auth, code: "the-code")
    #expect(tokens == OAuthClient.Tokens(accessToken: "at", refreshToken: "rt", idToken: idToken))
    #expect(tokens.email == "member@example.com")
  }

  @Test("a refresh posts the refresh token; a response without one keeps none")
  func refresh() async throws {
    let transport = FakeHTTPTransport { request in
      let form = Self.form(request)
      guard form["grant_type"] == "refresh_token", form["refresh_token"] == "r+t/="
      else { return (400, Data()) }
      return (200, json(["access_token": "fresh"]))
    }
    let tokens = try await client(transport).refresh("r+t/=")
    #expect(tokens == OAuthClient.Tokens(accessToken: "fresh", refreshToken: nil, idToken: nil))
  }

  @Test("the token endpoint's 400/401 is a refusal; 5xx, garbage and offline are unreachable")
  func tokenFailures() async {
    for (status, expected) in [(400, OAuthClient.Failure.rejected), (401, .rejected), (500, .unreachable)] {
      let transport = FakeHTTPTransport { _ in (status, json(["error": "invalid_grant"])) }
      await #expect(throws: expected) { try await client(transport).refresh("rt") }
    }
    let garbage = FakeHTTPTransport { _ in (200, Data("nope".utf8)) }
    await #expect(throws: OAuthClient.Failure.unreachable) { try await client(garbage).refresh("rt") }
    let offline = FakeHTTPTransport.failing(with: URLError(.notConnectedToInternet))
    await #expect(throws: OAuthClient.Failure.unreachable) { try await client(offline).refresh("rt") }
  }

  @Test("the exchange sends the bearer token and reads the key and its expiry")
  func exchange() async throws {
    let transport = FakeHTTPTransport { request in
      guard request.url == testOAuthConfiguration.apiKeyURL, request.httpMethod == "POST",
        request.value(forHTTPHeaderField: "Authorization") == "Bearer at"
      else { return (401, Data()) }
      return (200, json(["api_key": "key-1", "api_key_expires_at": "2026-11-01T00:00:00Z"]))
    }
    let key = try await client(transport).apiKey(accessToken: "at")
    #expect(key == OAuthClient.ConnectionKey(apiKey: "key-1", expiresAt: Date(timeIntervalSince1970: 1_793_491_200)))
    #expect(key.rotatesAt == nil)
  }

  @Test("the exchange reads when the key rotates, when the server says")
  func exchangeRotatesAt() async throws {
    let transport = FakeHTTPTransport { _ in
      (
        200,
        json([
          "api_key": "key-1", "api_key_expires_at": "2026-11-01T00:00:00Z",
          "api_key_rotates_at": "2026-10-30T00:00:00Z",
        ])
      )
    }
    let key = try await client(transport).apiKey(accessToken: "at")
    #expect(key.rotatesAt == Date(timeIntervalSince1970: 1_793_491_200 - 2 * 86_400))
  }

  @Test("an expiry with fractional seconds parses; a missing or odd one is nil")
  func expiryParsing() {
    #expect(OAuthClient.date(from: "2026-11-01T00:00:00.500Z") == Date(timeIntervalSince1970: 1_793_491_200.5))
    #expect(OAuthClient.date(from: "soon") == nil)
  }

  @Test("the exchange's 401 is a refusal, 403 carries its reason, anything else is unreachable")
  func exchangeFailures() async {
    let unauthorized = FakeHTTPTransport { _ in (401, Data()) }
    await #expect(throws: OAuthClient.Failure.rejected) { try await client(unauthorized).apiKey(accessToken: "at") }

    let scope = FakeHTTPTransport { _ in
      (403, json(["error": "insufficient_scope", "error_description": "missing aai:api"]))
    }
    await #expect(throws: OAuthClient.Failure.forbidden("missing aai:api")) {
      try await client(scope).apiKey(accessToken: "at")
    }

    let detail = FakeHTTPTransport { _ in (403, json(["detail": "Key disabled"])) }
    await #expect(throws: OAuthClient.Failure.forbidden("Key disabled")) {
      try await client(detail).apiKey(accessToken: "at")
    }

    let bare = FakeHTTPTransport { _ in (403, Data()) }
    await #expect(throws: OAuthClient.Failure.forbidden(nil)) { try await client(bare).apiKey(accessToken: "at") }

    let blankKey = FakeHTTPTransport { _ in (200, json(["api_key": " "])) }
    await #expect(throws: OAuthClient.Failure.unreachable) { try await client(blankKey).apiKey(accessToken: "at") }

    let down = FakeHTTPTransport { _ in (503, Data()) }
    await #expect(throws: OAuthClient.Failure.unreachable) { try await client(down).apiKey(accessToken: "at") }
  }

  @Test("revoke succeeds on 2xx; 401 is a refusal; 503 (grant revoke failed) is unreachable")
  func revoke() async throws {
    let ok = FakeHTTPTransport { request in
      guard request.url == testOAuthConfiguration.revokeURL, request.httpMethod == "POST",
        request.value(forHTTPHeaderField: "Authorization") == "Bearer at"
      else { return (404, Data()) }
      return (204, Data())
    }
    try await client(ok).revoke(accessToken: "at")

    let unauthorized = FakeHTTPTransport { _ in (401, Data()) }
    await #expect(throws: OAuthClient.Failure.rejected) { try await client(unauthorized).revoke(accessToken: "at") }
    let down = FakeHTTPTransport { _ in (503, Data()) }
    await #expect(throws: OAuthClient.Failure.unreachable) { try await client(down).revoke(accessToken: "at") }
  }

  @Test("the ID token's email is read when present, nil otherwise")
  func email() {
    func tokens(_ idToken: String?) -> OAuthClient.Tokens {
      OAuthClient.Tokens(accessToken: "at", refreshToken: nil, idToken: idToken)
    }
    #expect(tokens(unsignedJWT(["email": "a@b.co"])).email == "a@b.co")
    #expect(tokens(unsignedJWT(["sub": "member"])).email == nil)
    #expect(tokens("not-a-jwt").email == nil)
    #expect(tokens("a.%%%.c").email == nil)
    #expect(tokens(nil).email == nil)
  }
}

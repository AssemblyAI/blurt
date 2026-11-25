import Foundation
import Testing

@testable import AssemblyAI

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

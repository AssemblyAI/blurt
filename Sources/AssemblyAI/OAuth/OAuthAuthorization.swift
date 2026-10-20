import CryptoKit
import Foundation

/// Where an app signs a member in with "Sign in with AssemblyAI", and what it
/// asks for. Public client, authorization code with PKCE (RFC 7636): there is no
/// client secret to configure, because a desktop app can't keep one.
public struct OAuthConfiguration: Sendable, Equatable {
  /// The app's Connected App client id.
  public let clientID: String
  /// The consent page the member signs in and approves on.
  public let authorizeURL: URL
  /// The authorization server's token endpoint (code exchange and refresh).
  public let tokenURL: URL
  /// AssemblyAI's exchange: an access token in, the connection's API key out.
  public let apiKeyURL: URL
  /// Ends the connection: revokes the grant and disables its key.
  public let revokeURL: URL
  /// Where the consent page sends the member back. A custom scheme, so the
  /// system's web authentication session can catch it without a listener.
  public let redirectURI: URL
  public let scopes: [String]

  /// The scopes a key exchange needs: `aai:api` is what the exchange checks for,
  /// `offline_access` gets a refresh token, `openid email` an ID token naming the
  /// member.
  public static let defaultScopes = ["openid", "email", "offline_access", "aai:api"]

  public init(
    clientID: String, authorizeURL: URL, tokenURL: URL, apiKeyURL: URL, revokeURL: URL,
    redirectURI: URL, scopes: [String] = OAuthConfiguration.defaultScopes
  ) {
    self.clientID = clientID
    self.authorizeURL = authorizeURL
    self.tokenURL = tokenURL
    self.apiKeyURL = apiKeyURL
    self.revokeURL = revokeURL
    self.redirectURI = redirectURI
    self.scopes = scopes
  }

  /// The redirect's scheme, which is what a web authentication session listens
  /// for.
  public var callbackScheme: String? { redirectURI.scheme }
}

/// One sign-in attempt: the consent page URL, plus the PKCE verifier and `state`
/// the callback has to be checked against. Single use; a new attempt makes a
/// new one.
public struct OAuthAuthorization: Sendable {
  /// Why a callback carried no usable code.
  public enum CallbackError: Error, Sendable, Equatable {
    /// The member declined on the consent page.
    case denied
    /// The callback's `state` isn't this attempt's: a stale or forged redirect.
    case stateMismatch
    /// The authorization server reported an error other than a decline, or the
    /// callback carried neither a code nor an error.
    case failed(String?)
  }

  public let configuration: OAuthConfiguration
  /// Sent at the token endpoint; its hash went out on the consent page URL.
  public let codeVerifier: String
  public let state: String

  /// `randomBytes` is injectable so tests get a fixed verifier and state.
  public init(
    configuration: OAuthConfiguration,
    randomBytes: (Int) -> [UInt8] = OAuthAuthorization.secureRandomBytes
  ) {
    self.configuration = configuration
    // 32 bytes → a 43-character verifier, the shortest RFC 7636 allows.
    self.codeVerifier = Self.base64URL(randomBytes(32))
    self.state = Self.base64URL(randomBytes(16))
  }

  /// The S256 challenge for `codeVerifier`.
  public var codeChallenge: String {
    Self.base64URL(Array(SHA256.hash(data: Data(codeVerifier.utf8))))
  }

  /// The consent page URL to open.
  public var url: URL {
    guard var components = URLComponents(url: configuration.authorizeURL, resolvingAgainstBaseURL: false)
    else { return configuration.authorizeURL }
    let existing = components.queryItems ?? []
    components.queryItems =
      existing + [
        URLQueryItem(name: "client_id", value: configuration.clientID),
        URLQueryItem(name: "redirect_uri", value: configuration.redirectURI.absoluteString),
        URLQueryItem(name: "response_type", value: "code"),
        URLQueryItem(name: "scope", value: configuration.scopes.joined(separator: " ")),
        URLQueryItem(name: "state", value: state),
        URLQueryItem(name: "code_challenge", value: codeChallenge),
        URLQueryItem(name: "code_challenge_method", value: "S256"),
      ]
    return components.url ?? configuration.authorizeURL
  }

  /// The authorization code from the redirect, after checking it answers this
  /// attempt.
  public func code(fromCallback callback: URL) throws(CallbackError) -> String {
    let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
    func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

    // `state` first: an error redirect that isn't ours says nothing about this
    // attempt either.
    guard value("state") == state else { throw .stateMismatch }
    if let error = value("error") {
      throw error == "access_denied" ? .denied : .failed(value("error_description") ?? error)
    }
    guard let code = value("code")?.trimmedNonEmpty() else { throw .failed(nil) }
    return code
  }

  public static func secureRandomBytes(_ count: Int) -> [UInt8] {
    var generator = SystemRandomNumberGenerator()
    return (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
  }

  static func base64URL(_ bytes: [UInt8]) -> String {
    Data(bytes).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}

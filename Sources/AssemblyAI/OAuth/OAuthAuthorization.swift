import CryptoKit
public import Foundation

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

  /// The S256 challenge for `codeVerifier`.
  public var codeChallenge: String {
    Self.base64URL(Array(SHA256.hash(data: Data(codeVerifier.utf8))))
  }

  /// The consent page URL to open.
  public var url: URL {
    guard var components = URLComponents(url: configuration.authorizeURL, resolvingAgainstBaseURL: false)
    else {
      return configuration.authorizeURL
    }
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

  /// `randomBytes` is injectable so tests get a fixed verifier and state.
  public init(
    configuration: OAuthConfiguration,
    randomBytes: (Int) -> [UInt8] = Self.secureRandomBytes
  ) {
    self.configuration = configuration
    // 32 bytes → a 43-character verifier, the shortest RFC 7636 allows.
    self.codeVerifier = Self.base64URL(randomBytes(32))
    self.state = Self.base64URL(randomBytes(16))
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
}

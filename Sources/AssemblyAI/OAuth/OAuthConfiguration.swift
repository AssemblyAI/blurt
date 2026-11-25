public import Foundation

/// Where an app signs a member in with "Sign in with AssemblyAI", and what it
/// asks for. Public client, authorization code with PKCE (RFC 7636): there is no
/// client secret to configure, because a desktop app can't keep one.
public struct OAuthConfiguration: Sendable, Equatable {
  /// The scopes a key exchange needs: `aai:api` is what the exchange checks for,
  /// `offline_access` gets a refresh token, `openid email` an ID token naming the
  /// member.
  public static let defaultScopes = ["openid", "email", "offline_access", "aai:api"]

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

  /// The redirect's scheme, which is what a web authentication session listens
  /// for.
  public var callbackScheme: String? { redirectURI.scheme }

  public init(
    clientID: String,
    authorizeURL: URL,
    tokenURL: URL,
    apiKeyURL: URL,
    revokeURL: URL,
    redirectURI: URL,
    scopes: [String] = Self.defaultScopes
  ) {
    self.clientID = clientID
    self.authorizeURL = authorizeURL
    self.tokenURL = tokenURL
    self.apiKeyURL = apiKeyURL
    self.revokeURL = revokeURL
    self.redirectURI = redirectURI
    self.scopes = scopes
  }
}

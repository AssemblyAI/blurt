public import Foundation
import os

/// The network half of "Sign in with AssemblyAI": the token endpoint (code
/// exchange, refresh) and AssemblyAI's own two routes, the API-key exchange and
/// the connection's revoke.
public struct OAuthClient: Sendable {
  /// Tokens from the token endpoint. A refresh may or may not rotate the refresh
  /// token; when it does, the old one stops working, so the caller must keep the
  /// new one.
  public struct Tokens: Sendable, Equatable {
    /// The one ID-token claim this client reads.
    private struct Claims: Decodable {
      let email: String?
    }

    public let accessToken: String
    public let refreshToken: String?
    public let idToken: String?

    /// The `email` claim of the ID token, for showing who is signed in. Read
    /// without verifying the signature: it is display text from a token this
    /// client just received over TLS, never an authorization decision.
    public var email: String? {
      guard let idToken else {
        return nil
      }
      let parts = idToken.split(separator: ".")
      guard parts.count >= 2 else {
        return nil
      }
      var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
      payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
      guard let data = Data(base64Encoded: payload),
        let claims = try? JSONDecoder().decode(Claims.self, from: data)
      else {
        return nil
      }
      return claims.email?.trimmedNonEmpty()
    }

    public init(accessToken: String, refreshToken: String?, idToken: String?) {
      self.accessToken = accessToken
      self.refreshToken = refreshToken
      self.idToken = idToken
    }
  }

  /// The connection's API key and when it stops working.
  public struct ConnectionKey: Sendable, Equatable {
    public let apiKey: String
    public let expiresAt: Date?
    /// From when an exchange mints the next key: when to exchange again. Nil
    /// from a server that doesn't say.
    public let rotatesAt: Date?

    public init(apiKey: String, expiresAt: Date?, rotatesAt: Date? = nil) {
      self.apiKey = apiKey
      self.expiresAt = expiresAt
      self.rotatesAt = rotatesAt
    }
  }

  public enum Failure: Error, Sendable, Equatable {
    /// The credential was refused: an expired or revoked refresh token, an access
    /// token the exchange won't take. Signing in again is the way back.
    case rejected
    /// The exchange refused this member (a role without API access, a disabled
    /// key or project). Carries the server's explanation when it gave one.
    case forbidden(String?)
    /// Couldn't reach the server, or it failed (5xx, 429, a malformed body).
    /// Nothing was decided; retry later.
    case unreachable
  }

  private struct TokenBody: Decodable {
    enum CodingKeys: String, CodingKey {
      case accessToken = "access_token"
      case refreshToken = "refresh_token"
      case idToken = "id_token"
    }

    let accessToken: String
    let refreshToken: String?
    let idToken: String?
  }

  private struct APIKeyBody: Decodable {
    enum CodingKeys: String, CodingKey {
      case apiKey = "api_key"
      case apiKeyExpiresAt = "api_key_expires_at"
      case apiKeyRotatesAt = "api_key_rotates_at"
    }

    let apiKey: String
    let apiKeyExpiresAt: String?
    let apiKeyRotatesAt: String?
  }

  /// A refused call's body: an OAuth error (`error`, `error_description`) or
  /// FastAPI's `detail`. Each field is read on its own, so one of another type
  /// (FastAPI's validation array for `detail`) doesn't lose the rest.
  private struct ErrorBody: Decodable {
    enum CodingKeys: String, CodingKey {
      case error, detail
      case errorDescription = "error_description"
    }

    let error: String?
    let errorDescription: String?
    let detail: String?

    init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      error = try? container.decode(String.self, forKey: .error)
      errorDescription = try? container.decode(String.self, forKey: .errorDescription)
      detail = try? container.decode(String.self, forKey: .detail)
    }

    /// The body, or nil when it isn't a JSON object (a proxy's page).
    static func parse(_ data: Data) -> Self? {
      try? JSONDecoder().decode(Self.self, from: data)
    }
  }

  /// RFC 3339 with fractional seconds, tried first by `date(from:)`, then
  /// without them.
  private static let fractionalSeconds = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
  private static let wholeSeconds = Date.ISO8601FormatStyle()

  private let configuration: OAuthConfiguration
  private let transport: any HTTPTransport
  private let userAgent: String?

  public init(
    configuration: OAuthConfiguration,
    transport: any HTTPTransport = URLSession.shared,
    userAgent: String? = nil
  ) {
    self.configuration = configuration
    self.transport = transport
    self.userAgent = userAgent
  }

  /// Logs a refused or failed call: the path, the status, and the body's
  /// `error`, `error_description` or `detail` (an OAuth error or FastAPI's).
  /// Those fields describe the failure, never carry a credential.
  static func logRefusal(_ request: URLRequest, status: Int, data: Data) {
    let path = request.url?.path ?? "?"
    let body = ErrorBody.parse(data)
    let fields = [
      ("error", body?.error),
      ("error_description", body?.errorDescription),
      ("detail", body?.detail),
    ]
    let named = fields.compactMap { key, value in value.map { "\(key)=\($0)" } }
    let reason = named.isEmpty ? "-" : named.joined(separator: " ")
    SDKLog.oauth.error("\(path, privacy: .public) -> \(status, privacy: .public): \(reason, privacy: .public)")
  }

  /// Whether a token-endpoint error body names a dead credential: the refresh
  /// token or code (`invalid_grant`) or the client (`invalid_client`).
  static func isRefusedGrant(_ data: Data) -> Bool {
    ["invalid_grant", "invalid_client"].contains(ErrorBody.parse(data)?.error)
  }

  /// The 403's reason: `error_description` from an `insufficient_scope` body, or
  /// FastAPI's `detail`.
  static func explanation(in data: Data) -> String? {
    guard let body = ErrorBody.parse(data) else {
      return nil
    }
    return (body.errorDescription ?? body.detail)?.trimmedNonEmpty()
  }

  /// RFC 3339, with or without fractional seconds.
  static func date(from string: String) -> Date? {
    (try? fractionalSeconds.parse(string)) ?? (try? wholeSeconds.parse(string))
  }

  static func formEncoded(_ fields: [String: String]) -> String {
    // RFC 3986 unreserved characters only: `+`, `&` and `=` in a value would
    // otherwise be read as form syntax.
    let allowed = CharacterSet(
      charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )
    return fields.sorted { $0.key < $1.key }
      .map { key, value in
        let escaped = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
        return "\(key)=\(escaped)"
      }
      .joined(separator: "&")
  }

  /// Trades the consent page's code for tokens.
  public func tokens(for authorization: OAuthAuthorization, code: String) async throws(Failure) -> Tokens {
    try await tokenRequest([
      "grant_type": "authorization_code",
      "client_id": configuration.clientID,
      "code": code,
      "code_verifier": authorization.codeVerifier,
      "redirect_uri": configuration.redirectURI.absoluteString,
    ])
  }

  /// A fresh access token from the refresh token.
  public func refresh(_ refreshToken: String) async throws(Failure) -> Tokens {
    try await tokenRequest([
      "grant_type": "refresh_token",
      "client_id": configuration.clientID,
      "refresh_token": refreshToken,
    ])
  }

  /// The connection's API key for this access token. The same key comes back on
  /// every call until it expires; the first call after that mints the next one.
  public func apiKey(accessToken: String) async throws(Failure) -> ConnectionKey {
    let request = authorizedPost(configuration.apiKeyURL, accessToken: accessToken)
    let (status, data) = try await send(request)
    switch status {
    case 200..<300:
      guard let body = try? JSONDecoder().decode(APIKeyBody.self, from: data),
        let apiKey = body.apiKey.trimmedNonEmpty()
      else { throw .unreachable }
      return ConnectionKey(
        apiKey: apiKey,
        expiresAt: body.apiKeyExpiresAt.flatMap(Self.date(from:)),
        rotatesAt: body.apiKeyRotatesAt.flatMap(Self.date(from:))
      )

    case 401:
      throw .rejected

    case 403:
      throw .forbidden(Self.explanation(in: data))

    default:
      throw .unreachable
    }
  }

  /// Ends the connection server-side: the grant is revoked and the key disabled.
  /// Succeeds when there was nothing left to end.
  public func revoke(accessToken: String) async throws(Failure) {
    let request = authorizedPost(configuration.revokeURL, accessToken: accessToken)
    let (status, _) = try await send(request)
    switch status {
    case 200..<300:
      return

    case 401:
      throw .rejected

    // 503 is the server saying the grant revoke failed: the grant is still
    // live, so this must not look like a sign-out.
    default:
      throw .unreachable
    }
  }

  private func tokenRequest(_ fields: [String: String]) async throws(Failure) -> Tokens {
    var request = URLRequest(url: configuration.tokenURL)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setUserAgent(userAgent)
    request.httpBody = Data(Self.formEncoded(fields).utf8)

    let (status, data) = try await send(request)
    switch status {
    case 200..<300:
      guard let body = try? JSONDecoder().decode(TokenBody.self, from: data),
        let accessToken = body.accessToken.trimmedNonEmpty()
      else { throw .unreachable }
      return Tokens(
        accessToken: accessToken,
        refreshToken: body.refreshToken?.trimmedNonEmpty(),
        idToken: body.idToken?.trimmedNonEmpty()
      )

    // RFC 6749 §5.2: a refused grant is a 400 or 401 whose `error` names it.
    // Only `invalid_grant` and `invalid_client` say the credential is dead; any
    // other 400 (`invalid_request` mid-deploy, a proxy's own page) says nothing
    // about it, and reading it as a refusal would sign the user out.
    case 400...401 where Self.isRefusedGrant(data):
      throw .rejected

    default:
      throw .unreachable
    }
  }

  private func authorizedPost(_ url: URL, accessToken: String) -> URLRequest {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setUserAgent(userAgent)
    return request
  }

  /// The response's status and body. Every refused or failed call is logged
  /// here, once, so the callers only map the status to a `Failure`.
  private func send(_ request: URLRequest) async throws(Failure) -> (Int, Data) {
    let status: Int
    let data: Data
    do {
      let (body, response) = try await transport.data(for: request)
      guard let http = response as? HTTPURLResponse else { throw Failure.unreachable }
      (status, data) = (http.statusCode, body)
    } catch {
      throw .unreachable
    }
    if !(200..<300).contains(status) { Self.logRefusal(request, status: status, data: data) }
    return (status, data)
  }
}

import AssemblyAI
import Foundation

extension OAuthConfiguration {
  /// The Info.plist keys a build sets to turn sign-in on. They come from build
  /// settings in `App/Blurt/project.yml`, so a build without them (release,
  /// until a production Connected App exists) offers only the paste-a-key path.
  public enum InfoKey {
    /// The Connected App's client id.
    public static let clientID = "BlurtOAuthClientID"
    /// The authorization server's token endpoint.
    public static let tokenURL = "BlurtOAuthTokenURL"
    /// The dashboard's consent page.
    public static let authorizeURL = "BlurtOAuthAuthorizeURL"
    /// The AssemblyAI web origin that serves the key routes
    /// (`/api/v2/oauth/api-key[/revoke]`). In production the same host as the
    /// consent page; on staging the dashboard and the site deploy apart.
    public static let apiOrigin = "BlurtOAuthAPIOrigin"
    /// The dictation host a signed-in key belongs to (`DictationOrigin`).
    /// Optional: unset, a signed-in key dictates against production.
    public static let dictationOrigin = "BlurtOAuthDictationOrigin"
  }

  /// Blurt's redirect. ASWebAuthenticationSession catches the scheme itself, so
  /// the app registers no URL handler; the Connected App must list it exactly.
  /// A reverse-domain private-use scheme, as RFC 8252 §7.1 asks, so it can't
  /// collide with another app's. `://` rather than RFC 8252's single slash
  /// because Stytch refuses a redirect URL without it.
  public static let blurtRedirectURI = URL(staticString: "com.assemblyai.blurt://oauth/callback")

  /// The dictation host this build's sign-in mints keys for, or nil (unset,
  /// blank, or neither https nor loopback http) for production.
  public static func blurtDictationOrigin(infoDictionary: [String: Any]) -> URL? {
    guard let value = (infoDictionary[InfoKey.dictationOrigin] as? String)?.trimmedNonEmpty(),
      let url = URL(string: value), isAllowed(url)
    else { return nil }
    return url
  }

  /// https, or plain http to this machine (`localhost`, `127.0.0.1`, `::1`) so
  /// a dev build can point at a locally run dashboard or site. Nothing on the
  /// loopback interface leaves the Mac.
  static func isAllowed(_ url: URL) -> Bool {
    switch url.scheme {
    case "https": true
    case "http": ["localhost", "127.0.0.1", "::1"].contains(url.host() ?? "")
    default: false
    }
  }

  /// Sign-in as this build configures it, or nil when any key is missing,
  /// not https, or blank (an unset build setting expands to an empty string).
  public static func blurt(infoDictionary: [String: Any]) -> OAuthConfiguration? {
    func value(_ key: String) -> String? { (infoDictionary[key] as? String)?.trimmedNonEmpty() }
    guard let clientID = value(InfoKey.clientID),
      let tokenURL = value(InfoKey.tokenURL).flatMap(URL.init(string:)),
      let authorizeURL = value(InfoKey.authorizeURL).flatMap(URL.init(string:)),
      let origin = value(InfoKey.apiOrigin).flatMap(URL.init(string:)),
      [tokenURL, authorizeURL, origin].allSatisfy(isAllowed)
    else { return nil }
    return OAuthConfiguration(
      clientID: clientID,
      authorizeURL: authorizeURL,
      tokenURL: tokenURL,
      apiKeyURL: origin.appending(path: "api/v2/oauth/api-key"),
      revokeURL: origin.appending(path: "api/v2/oauth/api-key/revoke"),
      redirectURI: blurtRedirectURI)
  }
}

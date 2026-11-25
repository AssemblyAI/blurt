import Foundation
import Security
import Synchronization
import Testing

@testable import AssemblyAI
@testable import BlurtEngine

@Suite("OAuth configuration from Info.plist")
struct OAuthConfigurationInfoTests {
  private let info: [String: Any] = [
    OAuthConfiguration.InfoKey.clientID: "client",
    OAuthConfiguration.InfoKey.tokenURL: "https://auth.example.com/v1/oauth2/token",
    OAuthConfiguration.InfoKey.authorizeURL: "https://dashboard.example.com/dashboard/oauth/authorize",
    OAuthConfiguration.InfoKey.apiOrigin: "https://www.example.com",
  ]

  @Test("all four keys set: the consent page as given, the key routes under the API origin")
  func configured() throws {
    let config = try #require(OAuthConfiguration.blurt(infoDictionary: info))
    #expect(config.clientID == "client")
    #expect(config.authorizeURL.absoluteString == "https://dashboard.example.com/dashboard/oauth/authorize")
    #expect(config.apiKeyURL.absoluteString == "https://www.example.com/api/v2/oauth/api-key")
    #expect(config.revokeURL.absoluteString == "https://www.example.com/api/v2/oauth/api-key/revoke")
    #expect(config.redirectURI.absoluteString == "com.assemblyai.blurt://oauth/callback")
  }

  @Test("a missing, blank or non-https value turns sign-in off")
  func unconfigured() {
    #expect(OAuthConfiguration.blurt(infoDictionary: [:]) == nil)
    for key in info.keys {
      var blank = info
      blank[key] = " "
      #expect(OAuthConfiguration.blurt(infoDictionary: blank) == nil)
    }
    for key in info.keys where key != OAuthConfiguration.InfoKey.clientID {
      var http = info
      http[key] = "http://www.example.com"
      #expect(OAuthConfiguration.blurt(infoDictionary: http) == nil)
    }
  }

  @Test(
    "plain http is allowed to this machine, for a dev build on a local dashboard or site",
    arguments: ["localhost:3000", "127.0.0.1:3000", "[::1]:3000"])
  func loopback(host: String) {
    var local = info
    local[OAuthConfiguration.InfoKey.authorizeURL] = "http://\(host)/dashboard/oauth/authorize"
    #expect(OAuthConfiguration.blurt(infoDictionary: local) != nil)
  }

  @Test("plain http to a host that merely starts with localhost is refused")
  func loopbackLookalike() {
    var lookalike = info
    lookalike[OAuthConfiguration.InfoKey.apiOrigin] = "http://localhost.example.com"
    #expect(OAuthConfiguration.blurt(infoDictionary: lookalike) == nil)
  }
}

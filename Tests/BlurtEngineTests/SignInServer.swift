import Foundation
import Security
import Synchronization
import Testing

@testable import AssemblyAI
@testable import BlurtEngine

/// Answers the three sign-in routes from per-route statuses the test sets, and
/// records what was sent.
final class SignInServer: Sendable {
  struct State {
    var tokenStatus = 200
    var exchangeStatus = 200
    var revokeStatus = 204
    var codeGrantRefreshToken: String? = "rt-1"
    var rotatedRefreshToken: String? = "rt-2"
    var apiKey = "connection-key"
    var expiresAt = "2026-11-01T00:00:00Z"
    var rotatesAt: String?
    var refreshTokensSeen: [String] = []
    var exchanges = 0
    var revokes = 0
  }

  let state = Mutex(State())

  var transport: FakeHTTPTransport {
    FakeHTTPTransport { [self] request in
      state.withLock { state in
        switch request.url {
        case testOAuthConfiguration.tokenURL:
          return Self.tokenResponse(to: request, state: &state)

        case testOAuthConfiguration.apiKeyURL:
          state.exchanges += 1
          guard state.exchangeStatus == 200 else {
            return (state.exchangeStatus, Data())
          }
          var body = ["api_key": state.apiKey, "api_key_expires_at": state.expiresAt]
          body["api_key_rotates_at"] = state.rotatesAt
          return (200, json(body))

        case testOAuthConfiguration.revokeURL:
          state.revokes += 1
          return (state.revokeStatus, Data())

        default:
          return (404, Data())
        }
      }
    }
  }

  /// The token route: records the refresh token sent, then answers with the
  /// status the test set — a code grant's refresh token or a rotated one on success.
  private static func tokenResponse(to request: URLRequest, state: inout State) -> (Int, Data) {
    let body = String(bytes: request.httpBody ?? Data(), encoding: .utf8) ?? ""
    if let pair = body.split(separator: "&").first(where: { $0.hasPrefix("refresh_token=") }) {
      state.refreshTokensSeen.append(String(pair.dropFirst("refresh_token=".count)))
    }
    guard state.tokenStatus == 200 else {
      return (state.tokenStatus, json(["error": "invalid_grant"]))
    }
    var fields = ["access_token": "at", "id_token": unsignedJWT(["email": "member@example.com"])]
    if body.contains("authorization_code") {
      fields["refresh_token"] = state.codeGrantRefreshToken
    } else if let rotated = state.rotatedRefreshToken {
      fields["refresh_token"] = rotated
    }
    return (200, json(fields))
  }
}

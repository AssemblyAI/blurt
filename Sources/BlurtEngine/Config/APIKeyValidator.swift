import Foundation

/// Verifies an AssemblyAI API key with one cheap authenticated request.
///
/// Hits `GET /v2/transcript?limit=1` (list transcripts): it requires a valid key
/// but returns nothing billable. The setup wizard uses this to give the user real
/// "this key works" feedback before advancing, instead of silently accepting a
/// wrong key that would only fail later during dictation.
public struct APIKeyValidator: Sendable {
  /// Outcome of a validation attempt.
  public enum Result: Sendable, Equatable {
    /// AssemblyAI accepted the key.
    case valid
    /// AssemblyAI rejected the request as a client error (any 4xx except the
    /// transient 408/429) — a bad, malformed, or unauthorized key.
    case invalid
    /// Couldn't reach AssemblyAI, or got a transient/server status (network
    /// failure, 408, 429, 5xx) — couldn't determine whether the key is good.
    /// Distinct from `.invalid` so the caller can tell the user it's a
    /// connectivity problem (retry when online), not a rejected key. The key is
    /// not saved on this outcome.
    case unreachable
  }

  private let baseURL: URL
  private let transport: any HTTPTransport

  public init(
    baseURL: URL = URL(string: "https://api.assemblyai.com")!,
    transport: any HTTPTransport = URLSession.shared
  ) {
    self.baseURL = baseURL
    self.transport = transport
  }

  public func validate(_ key: String) async -> Result {
    guard let trimmed = key.trimmedNonEmpty() else { return .invalid }

    var components = URLComponents(
      url: baseURL.appendingPathComponent("v2/transcript"),
      resolvingAgainstBaseURL: false
    )
    components?.queryItems = [URLQueryItem(name: "limit", value: "1")]
    guard let url = components?.url else { return .unreachable }

    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    // AssemblyAI expects the raw key in Authorization (no "Bearer" prefix),
    // matching AssemblyAITranscriber.
    request.setValue(trimmed, forHTTPHeaderField: "Authorization")

    do {
      let (_, response) = try await transport.data(for: request)
      guard let http = response as? HTTPURLResponse else { return .unreachable }
      switch http.statusCode {
      case 200..<300: return .valid
      // 408 (request timeout) and 429 (rate limited) are transient — the key
      // may be perfectly good, so report unreachable (a retry-when-online error)
      // rather than rejecting it as invalid.
      case 408, 429: return .unreachable
      // Any other 4xx is a client error that means the key/request itself is
      // bad (401/403 auth rejection, 400/422 malformed). Treat as invalid so
      // the wizard shows a real error instead of silently saving a dead key.
      case 400..<500: return .invalid
      // 5xx and anything unexpected: server-side / can't determine — report
      // unreachable so the user retries rather than seeing a false rejection.
      default: return .unreachable
      }
    } catch {
      return .unreachable
    }
  }
}

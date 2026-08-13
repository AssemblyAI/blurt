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
    baseURL: URL = URL(staticString: "https://api.assemblyai.com"),
    transport: any HTTPTransport = URLSession.shared
  ) {
    self.baseURL = baseURL
    self.transport = transport
  }

  public func validate(_ key: String) async -> Result {
    guard let trimmed = key.trimmedNonEmpty() else { return .invalid }

    var components = URLComponents(
      url: baseURL.appendingPathComponent("v2/transcript"),
      // `true` would behave identically here: the URL above is already absolute, so
      // there is no base to resolve it against. Equivalent mutant, not a test gap.
      resolvingAgainstBaseURL: false  // mutate-ok: absolute URL, nothing to resolve
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
      // Only the statuses that actually mean "this credential was rejected" or
      // "this key is malformed" may report `.invalid`, because `.invalid` HARD
      // BLOCKS setup: `APIKeySubmission.submit` refuses to persist the key, so the
      // user can't finish onboarding with a key that works fine for dictation.
      // A blanket `400..<500` also caught the cases that say nothing about the key
      // — AssemblyAI retiring or moving this endpoint (404/405/410), or a corporate
      // proxy or captive portal interposing its own block page (451) — and told the
      // user their good key was rejected. Everything else falls through to
      // `.unreachable`, the outcome designed for "couldn't determine".
      // 403 stays on the rejected side: AssemblyAI answers an authenticated request
      // it won't serve with it, which is a verdict on the credential.
      case 401, 403, 400, 422: return .invalid
      // 5xx and anything unexpected: server-side / can't determine — report
      // unreachable so the user retries rather than seeing a false rejection.
      default: return .unreachable
      }
    } catch {
      return .unreachable
    }
  }
}

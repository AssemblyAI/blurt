import Foundation

/// The outcome of a successful update check.
public enum UpdateCheckResult: Sendable, Equatable {
  /// The running app is the latest published release (or newer).
  case upToDate(current: SemanticVersion)
  /// A newer release exists; `dmgURL` downloads its DMG in the browser.
  case available(version: SemanticVersion, dmgURL: URL)
}

/// Checks GitHub for a newer Blurt release. No AppKit and no in-place install —
/// it only reports whether a newer `.dmg` exists and where to download it. The
/// network call goes through the engine's shared `HTTPTransport` seam (same as
/// `AssemblyAITranscriber` / `APIKeyValidator`), so tests substitute a
/// `FakeHTTPTransport` instead of hitting the live API.
public struct UpdateChecker: Sendable {
  private let releaseURL: URL
  private let transport: any HTTPTransport

  public init(
    releaseURL: URL = URL(
      staticString: "https://api.github.com/repos/AssemblyAI/blurt/releases/latest"),
    transport: any HTTPTransport = URLSession.shared
  ) {
    self.releaseURL = releaseURL
    self.transport = transport
  }

  /// Fetches the latest release and compares it to `current`. Throws on network
  /// failure, malformed JSON, an unparseable tag, or a newer release with no
  /// DMG asset — the app maps any throw to a single "couldn't check" caption.
  public func check(current: SemanticVersion) async throws -> UpdateCheckResult {
    let (data, _) = try await transport.data(for: URLRequest(url: releaseURL))
    let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
    guard let latest = SemanticVersion(release.tagName) else {
      throw UpdateCheckError.malformedResponse
    }
    guard current < latest else {
      return .upToDate(current: current)
    }
    guard let asset = release.dmgAsset else {
      throw UpdateCheckError.malformedResponse
    }
    return .available(version: latest, dmgURL: asset.browserDownloadURL)
  }
}

/// The check couldn't produce a result from a well-formed HTTP response (an
/// unparseable tag, or a newer release with no DMG). Internal: the app catches
/// generically and shows one caption, so this never needs to be `public`.
enum UpdateCheckError: Error {
  case malformedResponse
}

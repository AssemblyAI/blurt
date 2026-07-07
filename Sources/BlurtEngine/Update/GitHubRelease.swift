import Foundation

/// The subset of GitHub's "get the latest release" response Blurt reads.
/// https://docs.github.com/en/rest/releases/releases#get-the-latest-release
///
/// Internal: only `UpdateChecker` (same module) decodes and inspects this —
/// the app consumes the digested `UpdateCheckResult`, never the raw release.
struct GitHubRelease: Decodable, Sendable {
  struct Asset: Decodable, Sendable {
    let name: String
    let browserDownloadURL: URL

    enum CodingKeys: String, CodingKey {
      case name
      case browserDownloadURL = "browser_download_url"
    }
  }

  let tagName: String
  let assets: [Asset]

  enum CodingKeys: String, CodingKey {
    case tagName = "tag_name"
    case assets
  }

  /// The first asset whose name ends in `.dmg` — the release pipeline publishes
  /// exactly one, `Blurt-<version>.dmg` (see `scripts/release-publish.sh`). Nil
  /// when the release carries no DMG.
  var dmgAsset: Asset? {
    assets.first { $0.name.lowercased().hasSuffix(".dmg") }
  }
}

import Foundation

/// The subset of GitHub's "get the latest release" response Blurt reads.
/// https://docs.github.com/en/rest/releases/releases#get-the-latest-release
public struct GitHubRelease: Decodable, Sendable {
  public struct Asset: Decodable, Sendable {
    public let name: String
    public let browserDownloadURL: URL

    enum CodingKeys: String, CodingKey {
      case name
      case browserDownloadURL = "browser_download_url"
    }
  }

  public let tagName: String
  public let assets: [Asset]

  enum CodingKeys: String, CodingKey {
    case tagName = "tag_name"
    case assets
  }

  /// The first asset whose name ends in `.dmg` — the release pipeline publishes
  /// exactly one, `Blurt-<version>.dmg` (see `scripts/release-publish.sh`). Nil
  /// when the release carries no DMG.
  public var dmgAsset: Asset? {
    assets.first { $0.name.lowercased().hasSuffix(".dmg") }
  }
}

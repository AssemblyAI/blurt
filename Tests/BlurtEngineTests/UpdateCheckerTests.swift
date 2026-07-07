import Foundation
import Testing

@testable import BlurtEngine

@Suite("UpdateChecker")
struct UpdateCheckerTests {
  /// A latest-release payload shaped like GitHub's, pinning the release
  /// pipeline's `Blurt-<version>.dmg` asset-naming convention.
  private func releaseJSON(tag: String, assetName: String = "Blurt-9.9.9.dmg") -> Data {
    Data(
      """
      {
        "tag_name": "\(tag)",
        "assets": [
          { "name": "SHA256SUMS", "browser_download_url": "https://example.com/SHA256SUMS" },
          { "name": "\(assetName)", "browser_download_url": "https://example.com/\(assetName)" }
        ]
      }
      """.utf8)
  }

  private func checker(returning data: Data) -> UpdateChecker {
    UpdateChecker(fetch: { _ in data })
  }

  @Test("reports .available with the DMG URL when the release is newer")
  func availableWhenNewer() async throws {
    let checker = checker(returning: releaseJSON(tag: "v0.2.0"))
    let current = try #require(SemanticVersion("0.1.30"))
    let result = try await checker.check(current: current)
    let expectedVersion = try #require(SemanticVersion("0.2.0"))
    let expectedURL = try #require(URL(string: "https://example.com/Blurt-9.9.9.dmg"))
    #expect(result == .available(version: expectedVersion, dmgURL: expectedURL))
  }

  @Test("reports .upToDate when the release matches the current version")
  func upToDateWhenSame() async throws {
    let checker = checker(returning: releaseJSON(tag: "v0.1.30"))
    let current = try #require(SemanticVersion("0.1.30"))
    let result = try await checker.check(current: current)
    #expect(result == .upToDate(current: current))
  }

  @Test("reports .upToDate when the release is older than the current build")
  func upToDateWhenOlder() async throws {
    let checker = checker(returning: releaseJSON(tag: "v0.1.0"))
    let current = try #require(SemanticVersion("0.1.30"))
    let result = try await checker.check(current: current)
    #expect(result == .upToDate(current: current))
  }

  @Test("throws when a newer release has no .dmg asset")
  func throwsWithoutDMG() async throws {
    let checker = checker(returning: releaseJSON(tag: "v0.2.0", assetName: "notes.txt"))
    let current = try #require(SemanticVersion("0.1.30"))
    await #expect(throws: (any Error).self) {
      try await checker.check(current: current)
    }
  }

  @Test("throws on an unparseable tag")
  func throwsOnBadTag() async throws {
    let checker = checker(returning: releaseJSON(tag: "nightly"))
    let current = try #require(SemanticVersion("0.1.30"))
    await #expect(throws: (any Error).self) {
      try await checker.check(current: current)
    }
  }

  @Test("throws on malformed JSON")
  func throwsOnMalformedJSON() async throws {
    let checker = checker(returning: Data("not json".utf8))
    let current = try #require(SemanticVersion("0.1.30"))
    await #expect(throws: (any Error).self) {
      try await checker.check(current: current)
    }
  }

  @Test("propagates a network failure from the fetch closure")
  func propagatesFetchError() async throws {
    let checker = UpdateChecker(fetch: { _ in throw URLError(.notConnectedToInternet) })
    let current = try #require(SemanticVersion("0.1.30"))
    await #expect(throws: (any Error).self) {
      try await checker.check(current: current)
    }
  }
}

import Testing

@testable import BlurtEngine

/// Pins the release pipeline's asset-naming convention (`Blurt-<version>.dmg`,
/// published by `scripts/release-publish.sh`) and the update prompt's wording —
/// a cross-repo contract that previously lived untested in the AppKit shell.
@Suite("UpdatePrompt")
struct UpdatePromptTests {
  @Test("parses the version out of a release asset name")
  func parsesReleaseAssetName() {
    #expect(UpdatePrompt.version(fromAssetNamed: "Blurt-1.2.3.dmg") == "1.2.3")
  }

  @Test("takes the part after the *last* hyphen")
  func lastHyphenWins() {
    #expect(UpdatePrompt.version(fromAssetNamed: "blurt-preview-0.9.dmg") == "0.9")
  }

  @Test("a name with no hyphen carries no version")
  func noHyphenIsNil() {
    // The prompt drops its version line rather than presenting the bare app
    // name ("Blurt Blurt is now available") as a version.
    #expect(UpdatePrompt.version(fromAssetNamed: "Blurt.dmg") == nil)
  }

  @Test("a trailing hyphen with nothing after it carries no version")
  func emptyTailIsNil() {
    #expect(UpdatePrompt.version(fromAssetNamed: "Blurt-.dmg") == nil)
  }

  @Test("full message when both versions are known")
  func messageWithBothVersions() {
    #expect(
      UpdatePrompt.message(newVersion: "1.2.0", currentVersion: "1.1.0")
        == "Blurt 1.2.0 is now available—you have 1.1.0. "
        + "Would you like to install it now? Blurt will quit and reopen to finish."
    )
  }

  @Test("drops the \"you have\" clause without a current version")
  func messageWithoutCurrentVersion() {
    #expect(
      UpdatePrompt.message(newVersion: "1.2.0", currentVersion: nil)
        == "Blurt 1.2.0 is now available. "
        + "Would you like to install it now? Blurt will quit and reopen to finish."
    )
  }

  @Test("drops the version line entirely without a new version")
  func messageWithoutNewVersion() {
    #expect(
      UpdatePrompt.message(newVersion: nil, currentVersion: "1.1.0")
        == "Would you like to install it now? Blurt will quit and reopen to finish."
    )
  }
}

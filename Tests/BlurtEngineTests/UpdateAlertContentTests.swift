import Foundation
import Testing

@testable import BlurtEngine

/// The wording an update check ends in. This used to be assembled inline at the
/// `NSAlert` call site in the app shell, which has no test target — so the
/// version arithmetic in the copy, the button order, and "which button
/// downloads" were all uncovered.
@Suite("UpdateAlertContent")
struct UpdateAlertContentTests {
  private func version(_ string: String) throws -> SemanticVersion {
    try #require(SemanticVersion(string))
  }

  private let dmg = URL(staticString: "https://example.com/Blurt.dmg")

  @Test("up to date names the running version and only dismisses")
  func upToDate() throws {
    let content = UpdateAlertContent.upToDate(current: try version("0.1.31"))
    #expect(content.title == "You’re up to date")
    #expect(content.message == "Blurt 0.1.31 is the latest version.")
    #expect(content.buttons == ["OK"])
    // Nothing to download, so the shell must not open anything.
    #expect(content.downloadURL == nil)
    #expect(content.style == .informational)
  }

  @Test("an available update names both versions and carries the DMG")
  func available() throws {
    let content = UpdateAlertContent.available(
      current: try version("0.1.31"), latest: try version("0.2.0"), dmgURL: dmg)
    #expect(content.title == "A new version of Blurt is available")
    #expect(content.message == "Blurt 0.2.0 is available—you have 0.1.31. Download it now?")
    #expect(content.downloadURL == dmg)
  }

  @Test("Download is the default action and Later dismisses")
  func availableButtonOrder() throws {
    let content = UpdateAlertContent.available(
      current: try version("1.0"), latest: try version("1.1"), dmgURL: dmg)
    // The shell opens `downloadURL` when the *first* button comes back, so the
    // order here is load-bearing: flipping it would make "Later" download.
    #expect(content.buttons == ["Download", "Later"])
    #expect(content.buttons.first == "Download")
  }

  @Test("couldn't check is a warning with no download")
  func checkFailed() {
    let content = UpdateAlertContent.checkFailed
    #expect(content.title == "Couldn’t check for updates")
    #expect(content.message == "Check your internet connection and try again.")
    #expect(content.buttons == ["OK"])
    #expect(content.downloadURL == nil)
    // The one caution: a result the user asked for isn't a warning, a failure is.
    #expect(content.style == .warning)
  }

  @Test("every alert offers at least one way out")
  func everyAlertIsDismissible() throws {
    let all = [
      UpdateAlertContent.upToDate(current: try version("1.0")),
      UpdateAlertContent.available(current: try version("1.0"), latest: try version("2.0"), dmgURL: dmg),
      .checkFailed,
    ]
    for content in all {
      #expect(!content.buttons.isEmpty)
    }
  }

  @Test("the result initializer maps both check outcomes")
  func resultMapping() throws {
    let current = try version("1.0.0")
    let latest = try version("1.1.0")
    #expect(
      UpdateAlertContent(result: .upToDate, current: current)
        == UpdateAlertContent.upToDate(current: current))
    #expect(
      UpdateAlertContent(result: .available(version: latest, dmgURL: dmg), current: current)
        == UpdateAlertContent.available(current: current, latest: latest, dmgURL: dmg))
  }

  @Test("the version label is shared by the alerts and the Settings row")
  func versionLabel() throws {
    #expect(UpdateAlertContent.appVersionLabel(try version("0.1.31")) == "Blurt 0.1.31")
    // A `v`-prefixed GitHub tag is stripped by SemanticVersion, so the label
    // never reads "Blurt v0.1.31".
    #expect(UpdateAlertContent.appVersionLabel(try version("v0.1.31")) == "Blurt 0.1.31")
  }

  @Test("an unparseable bundle version still yields a usable label")
  func versionLabelWithoutVersion() {
    // The Settings row's title falls back to the bare product name; the check
    // itself still runs, it just can't name what's running.
    #expect(UpdateAlertContent.appVersionLabel(nil) == "Blurt")
  }
}

import Foundation
import Testing

@testable import BlurtEngine

@Suite("UserAgent")
struct UserAgentTests {
  @Test("the agent is the product name, the short version, and the details as a comment")
  func productVersionAndComment() {
    #expect(
      UserAgent.value(product: "Blurt", version: "0.1.54", details: ["macOS 15.5", "dev"])
        == "Blurt/0.1.54 (macOS 15.5; dev)")
  }

  /// A release build sends one detail, so the comment must not gain a stray
  /// separator — the reason `details` is a list the formatter joins rather than
  /// a preformatted string each caller assembles.
  @Test("a single detail needs no separator")
  func singleDetail() {
    #expect(
      UserAgent.value(product: "Blurt", version: "0.1.54", details: ["macOS 26.1"])
        == "Blurt/0.1.54 (macOS 26.1)")
  }

  @Test("no details means no empty parentheses")
  func noDetails() {
    #expect(UserAgent.value(product: "Blurt", version: "0.1.54", details: []) == "Blurt/0.1.54")
  }

  @Test("blank details drop out rather than widening the comment")
  func blankDetailsDropped() {
    #expect(
      UserAgent.value(product: "Blurt", version: "0.1.54", details: ["", "  ", "macOS 15.5"])
        == "Blurt/0.1.54 (macOS 15.5)")
  }

  /// No version means no version token — not `Blurt/unknown`, which reads like
  /// one to anything parsing the header. See `UserAgent.value`.
  @Test(
    "a missing, blank, or whitespace-only version degrades to the bare product name",
    arguments: [nil, "", "   ", "\n"] as [String?])
  func missingVersionOmitsTheToken(version: String?) {
    #expect(UserAgent.value(product: "Blurt", version: version, details: []) == "Blurt")
    // The comment still applies without a version — the OS is worth knowing
    // even from a build that can't say which one it is.
    #expect(
      UserAgent.value(product: "Blurt", version: version, details: ["macOS 15.5"])
        == "Blurt (macOS 15.5)")
  }

  @Test("a surrounding-whitespace version is trimmed rather than sent as-is")
  func versionTrimmed() {
    #expect(UserAgent.value(product: "Blurt", version: " 0.1.54\n", details: []) == "Blurt/0.1.54")
  }

  /// A `User-Agent` product token may not contain whitespace. Blurt's own name
  /// has none, but `HostIdentity` exists so another app can supply its own.
  @Test("a multi-word product name becomes a single valid token")
  func multiWordProductHyphenated() {
    #expect(
      UserAgent.value(product: "Acme Voice", version: "2.0", details: []) == "Acme-Voice/2.0")
  }

  /// `UserAgent.current` resolves `HostIdentity.current.productName`, the
  /// bundle's `CFBundleShortVersionString`, the running OS and the build
  /// channel. Under `swift test` there is no versioned app bundle, so the
  /// version half is whatever the test runner's bundle carries (often nothing);
  /// the product name and the OS detail are the deterministic parts.
  @Test("the stamped agent names the host product and the running macOS version")
  func currentNamesProductAndOS() {
    let os = ProcessInfo.processInfo.operatingSystemVersion
    #expect(UserAgent.current.hasPrefix(HostIdentity.current.productName))
    #expect(UserAgent.current.contains("(macOS \(os.majorVersion).\(os.minorVersion)"))
  }

  /// The whole point of the channel detail: a build that isn't a release says
  /// so, keeping local `dev-build.sh` traffic out of the service-side baseline.
  /// A test run is a debug build, which is why this can be asserted at all —
  /// and `#expect` on the inverse under a release build would be asserting
  /// something this suite never compiles into.
  @Test("a non-release build marks itself dev")
  func debugBuildMarksItselfDev() {
    #if DEBUG
      #expect(UserAgent.current.hasSuffix("; dev)"))
    #endif
  }

  @Test("setUserAgent stamps the User-Agent header on a request")
  func stampsTheHeader() {
    var request = URLRequest(url: URL(staticString: "https://dictation.assemblyai.com/v1/transcribe/live"))
    request.setUserAgent()
    #expect(request.value(forHTTPHeaderField: "User-Agent") == UserAgent.current)
  }
}

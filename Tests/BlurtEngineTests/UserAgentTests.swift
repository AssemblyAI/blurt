import Foundation
import Testing

@testable import BlurtEngine

@Suite("UserAgent")
struct UserAgentTests {
  /// One `UserAgent.value(product:version:details:)` expectation.
  struct Case: Sendable, CustomTestStringConvertible {
    let name: String
    let product: String
    let version: String?
    let details: [String]
    let expected: String
    var testDescription: String { name }
  }

  static let cases: [Case] = [
    Case(
      name: "the agent is the product name, the short version, and the details as a comment",
      product: "Blurt",
      version: "0.1.54",
      details: ["macOS 15.5", "dev"],
      expected: "Blurt/0.1.54 (macOS 15.5; dev)"
    ),
    // A release build sends one detail, so the comment must not gain a stray
    // separator — the reason `details` is a list the formatter joins rather than
    // a preformatted string each caller assembles.
    Case(
      name: "a single detail needs no separator",
      product: "Blurt",
      version: "0.1.54",
      details: ["macOS 26.1"],
      expected: "Blurt/0.1.54 (macOS 26.1)"
    ),
    Case(
      name: "no details means no empty parentheses",
      product: "Blurt",
      version: "0.1.54",
      details: [],
      expected: "Blurt/0.1.54"
    ),
    Case(
      name: "blank details drop out rather than widening the comment",
      product: "Blurt",
      version: "0.1.54",
      details: ["", "  ", "macOS 15.5"],
      expected: "Blurt/0.1.54 (macOS 15.5)"
    ),
    Case(
      name: "a surrounding-whitespace version is trimmed rather than sent as-is",
      product: "Blurt",
      version: " 0.1.54\n",
      details: [],
      expected: "Blurt/0.1.54"
    ),
    // A `User-Agent` product token may not contain whitespace. Blurt's own name
    // has none, but `HostIdentity` exists so another app can supply its own.
    Case(
      name: "a multi-word product name becomes a single valid token",
      product: "Acme Voice",
      version: "2.0",
      details: [],
      expected: "Acme-Voice/2.0"
    ),
  ]

  @Test("value formats the product, version and details as one header", arguments: cases)
  func value(_ c: Case) {
    #expect(UserAgent.value(product: c.product, version: c.version, details: c.details) == c.expected)
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

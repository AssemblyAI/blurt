import Foundation
import Testing

@testable import BlurtEngine

@Suite("UserAgent")
struct UserAgentTests {
  @Test("the agent is the product name and the short version")
  func productSlashVersion() {
    #expect(UserAgent.value(product: "Blurt", version: "0.1.54") == "Blurt/0.1.54")
  }

  /// No version means no version token — not `Blurt/unknown`, which reads like
  /// one to anything parsing the header. See `UserAgent.value`.
  @Test(
    "a missing, blank, or whitespace-only version degrades to the bare product name",
    arguments: [nil, "", "   ", "\n"] as [String?])
  func missingVersionOmitsTheToken(version: String?) {
    #expect(UserAgent.value(product: "Blurt", version: version) == "Blurt")
  }

  @Test("a surrounding-whitespace version is trimmed rather than sent as-is")
  func versionTrimmed() {
    #expect(UserAgent.value(product: "Blurt", version: " 0.1.54\n") == "Blurt/0.1.54")
  }

  /// A `User-Agent` product token may not contain whitespace. Blurt's own name
  /// has none, but `HostIdentity` exists so another app can supply its own.
  @Test("a multi-word product name becomes a single valid token")
  func multiWordProductHyphenated() {
    #expect(UserAgent.value(product: "Acme Voice", version: "2.0") == "Acme-Voice/2.0")
  }

  /// `UserAgent.current` resolves `HostIdentity.current.productName` and the
  /// bundle's `CFBundleShortVersionString`. Under `swift test` there is no
  /// versioned app bundle, so the version half is whatever the test runner's
  /// bundle happens to carry (often nothing) — the product half is the part
  /// that is deterministic here, and the part the request assertions rely on.
  @Test("the stamped agent names the host product")
  func currentNamesTheProduct() {
    #expect(UserAgent.current.hasPrefix(HostIdentity.current.productName))
  }

  @Test("setUserAgent stamps the User-Agent header on a request")
  func stampsTheHeader() {
    var request = URLRequest(url: URL(staticString: "https://dictation.assemblyai.com/v1/transcribe/live"))
    request.setUserAgent()
    #expect(request.value(forHTTPHeaderField: "User-Agent") == UserAgent.current)
  }
}

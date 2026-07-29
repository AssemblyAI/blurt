import Testing

@testable import BlurtEngine

/// Pins the browser classification behind the injector's AX-opaque exemption
/// (see `FocusCapture.isAXOpaqueApp`): a known browser pastes even when the
/// focused element exposes no editable AX signal, because web content is
/// routinely opaque (Chromium's lazy accessibility tree, `contenteditable`
/// composers like ChatGPT's) — "no signal" there means "AX can't see the
/// field," not "no field."
@Suite("FocusCapture.isBrowserBundleID")
struct BrowserBundleIDTests {
  @Test(
    "known browser bundle IDs classify as browsers",
    arguments: [
      "com.apple.Safari",
      "com.google.Chrome",
      "org.chromium.Chromium",
      "com.microsoft.edgemac",
      "com.brave.Browser",
      "com.operasoftware.Opera",
      "com.vivaldi.Vivaldi",
      "company.thebrowser.Browser",
      "org.mozilla.firefox",
      "com.duckduckgo.macos.browser",
      "com.kagi.kagimacOS",
    ])
  func knownBrowsers(bundleID: String) {
    #expect(FocusCapture.isBrowserBundleID(bundleID))
  }

  @Test(
    "channel variants classify with their stable siblings (prefix match)",
    arguments: [
      "com.apple.SafariTechnologyPreview",
      "com.google.Chrome.beta",
      "com.google.Chrome.canary",
      "com.microsoft.edgemac.Dev",
      "com.brave.Browser.nightly",
    ])
  func channelVariants(bundleID: String) {
    #expect(FocusCapture.isBrowserBundleID(bundleID))
  }

  @Test(
    "non-browser apps are not browsers — they keep the copy-don't-beep fallback",
    arguments: [
      "com.apple.finder",
      "com.apple.TextEdit",
      "com.apple.dt.Xcode",
      "com.microsoft.VSCode",  // Electron: exempted by isElectronApp, not here
      "com.googlecode.iterm2",  // "com.google" lookalike must not prefix-match
    ])
  func nonBrowsers(bundleID: String) {
    #expect(!FocusCapture.isBrowserBundleID(bundleID))
  }

  @Test("a nil bundle ID is not a browser")
  func nilBundleID() {
    #expect(!FocusCapture.isBrowserBundleID(nil))
  }
}

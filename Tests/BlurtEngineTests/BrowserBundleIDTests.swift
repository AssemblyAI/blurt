import AppKit
import Foundation
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

/// The other half of the AX-opaque exemption: Electron detection, and the
/// `isAXOpaqueApp` disjunction the injector actually calls.
///
/// Electron apps are classified by the framework they bundle rather than by
/// bundle ID, because the set is open-ended (every Electron app ever shipped),
/// so the fixtures here are directory trees rather than identifier strings —
/// `isElectronBundle` is split out of the `NSRunningApplication` wrapper for
/// exactly that reason.
@Suite("FocusCapture AX-opaque app classification")
struct AXOpaqueAppTests {

  /// An app bundle skeleton in a temp directory, with the Electron framework
  /// present or absent. Only the *path* matters to the check — nothing is loaded —
  /// so an empty directory at the framework's location is a faithful fixture.
  private func makeBundle(withElectron: Bool) throws -> URL {
    let bundle = URL.temporaryDirectory.appending(path: "Blurt-\(UUID().uuidString).app")
    let contents =
      withElectron
      ? bundle.appending(path: "Contents/Frameworks/Electron Framework.framework")
      : bundle.appending(path: "Contents/Frameworks")
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    return bundle
  }

  // MARK: isElectronBundle

  @Test("a bundle shipping the Electron framework is Electron")
  func electronBundleDetected() throws {
    let bundle = try makeBundle(withElectron: true)
    defer { try? FileManager.default.removeItem(at: bundle) }
    // The true arm is what keeps VS Code and Slack on the paste path: their focused
    // text fields expose no editable AX signal, so without this they'd fall back to
    // copy-only and the user's words would never land.
    #expect(FocusCapture.isElectronBundle(bundle))
  }

  @Test("a native bundle with no Electron framework is not Electron")
  func nativeBundleRejected() throws {
    let bundle = try makeBundle(withElectron: false)
    defer { try? FileManager.default.removeItem(at: bundle) }
    // The false arm matters just as much: a native app with genuinely nothing
    // editable focused must fall back to copy rather than beep a ⌘V.
    #expect(!FocusCapture.isElectronBundle(bundle))
  }

  @Test("a bundle URL that doesn't exist is not Electron")
  func missingBundleRejected() {
    #expect(!FocusCapture.isElectronBundle(URL(filePath: "/nonexistent/Ghost.app")))
  }

  @Test("a nil bundle URL is not Electron")
  func nilBundleURLRejected() {
    #expect(!FocusCapture.isElectronBundle(nil))
  }

  // MARK: NSRunningApplication wrappers

  @Test("the test host is neither a browser nor Electron")
  func testHostIsNotOpaque() {
    // The one live `NSRunningApplication` a unit test can count on. Weak as an
    // assertion about *this* process, but it pins the wrappers as pass-throughs to
    // the two pure checks rather than, say, defaulting to opaque — which would make
    // the injector paste into every non-editable target and beep.
    let current = NSRunningApplication.current
    #expect(!FocusCapture.isBrowserApp(current))
    #expect(!FocusCapture.isElectronApp(current))
    #expect(!FocusCapture.isAXOpaqueApp(current))
  }

  @Test("no app at all is not AX-opaque")
  func nilAppIsNotOpaque() {
    // `KeyInjector` passes its captured target, which is nil when nothing was
    // captured — that must not be treated as opaque, or a paste with no known
    // target would be attempted anyway.
    #expect(!FocusCapture.isBrowserApp(nil))
    #expect(!FocusCapture.isElectronApp(nil))
    #expect(!FocusCapture.isAXOpaqueApp(nil))
  }
}

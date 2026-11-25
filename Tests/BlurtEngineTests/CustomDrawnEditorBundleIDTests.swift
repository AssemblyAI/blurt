#if os(macOS)
  import AppKit
  import Foundation
  import Testing

  @testable import BlurtEngine

  /// The custom-drawn-editor arm of the AX-opaque exemption: native editors like
  /// Sublime Text and Zed that render their own text view and expose no AX text
  /// element, so they paste on no signal just as browsers and Electron apps do.
  @Suite("FocusCapture.isCustomDrawnEditorBundleID")
  struct CustomDrawnEditorBundleIDTests {
    @Test(
      "known custom-drawn editors classify, channel variants included",
      arguments: [
        "com.sublimetext.4",
        "com.sublimetext.3",
        "com.sublimemerge",
        "dev.zed.Zed",
        "dev.zed.Zed-Preview",
        "dev.zed.Zed-Nightly",
      ])
    func knownEditors(bundleID: String) {
      #expect(FocusCapture.isCustomDrawnEditorBundleID(bundleID))
    }

    @Test(
      "other apps keep the copy-don't-beep fallback",
      arguments: [
        "com.apple.TextEdit",
        "com.apple.finder",
        "com.sublimetext",  // the prefix carries the trailing dot
        "com.microsoft.VSCode",
      ])
    func others(bundleID: String) {
      #expect(!FocusCapture.isCustomDrawnEditorBundleID(bundleID))
    }

    @Test("a nil bundle ID is not a custom-drawn editor")
    func nilBundleID() {
      #expect(!FocusCapture.isCustomDrawnEditorBundleID(nil))
    }
  }
#endif

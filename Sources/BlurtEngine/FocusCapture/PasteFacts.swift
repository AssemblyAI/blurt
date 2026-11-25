#if os(macOS)
  import Foundation

  /// What decides whether a dictation is pasted or left on the clipboard,
  /// read off the focused element and its app at paste time — and nothing
  /// else: no text, no labels. Recorded from real apps as fixtures
  /// (`Tests/PasteFixtures`) and replayed through `PasteTarget.pastes`, the
  /// same decision `KeyInjector` makes, so a paste situation that worked keeps
  /// working.
  struct PasteFacts: Codable, Equatable, Sendable {
    /// Whether anything was focused at all.
    var focused: Bool
    var role: String?
    var subrole: String?
    var valueSettable = false
    /// Whether it reports a selected-text range: an insertion point.
    var hasInsertionPoint = false
    /// Whether it sits inside a web view's page (`FocusCapture.isInWebArea`).
    var inWebArea = false
    /// The app's bundle id, and whether it bundles Electron.
    var bundleID: String?
    var electron = false
  }
#endif

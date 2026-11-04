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

  enum PasteTarget {
    // periphery:ignore - the whole decision the paste fixtures replay; KeyInjector joins the same two halves.
    /// Whether these facts mean a paste: an app that hides its text fields from
    /// Accessibility (a browser, Electron, a custom-drawn editor) is pasted into
    /// whatever it reports, as `KeyInjector` does (`FocusCapture.isAXOpaqueApp`
    /// over a bundle id and the Electron probe's answer); otherwise only a focused
    /// element that reads as editable (`FocusCapture.isEditableTarget`).
    static func pastes(_ facts: PasteFacts) -> Bool {
      FocusCapture.isAXOpaqueBundleID(facts.bundleID) || facts.electron || fieldTakesPaste(facts)
    }

    /// The focused element's half of the decision — what
    /// `FocusCapture.hasEditableFocusedElement` answers the injector with.
    static func fieldTakesPaste(_ facts: PasteFacts) -> Bool {
      guard facts.focused else { return false }
      return FocusCapture.isEditableTarget(
        role: facts.role, valueSettable: facts.valueSettable, hasInsertionPoint: facts.hasInsertionPoint,
        inWebArea: facts.inWebArea)
    }
  }
#endif

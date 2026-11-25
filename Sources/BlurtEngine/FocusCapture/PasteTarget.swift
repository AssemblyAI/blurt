#if os(macOS)
  enum PasteTarget {
    // periphery:ignore - the whole decision the paste fixtures replay; KeyInjector joins the same two halves.
    /// Whether these facts mean a paste: an app that hides its text fields from
    /// Accessibility (a browser, Electron, a custom-drawn editor) is pasted into
    /// whatever it reports, as `KeyInjector` does (`FocusCapture.isAXOpaqueApp`
    /// over a bundle id and the Electron probe's answer); otherwise only a focused
    /// element that reads as editable (`FocusCapture.isEditableTarget`).
    static func pastes(_ facts: PasteFacts) -> Bool {  // swiftlint:disable:this unused_declaration
      // Only the test target calls this (the paste fixtures replay it), and the analyzer
      // reads the app build's log, which doesn't compile the tests.
      FocusCapture.isAXOpaqueBundleID(facts.bundleID) || facts.electron || fieldTakesPaste(facts)
    }

    /// The focused element's half of the decision — what
    /// `FocusCapture.hasEditableFocusedElement` answers the injector with.
    static func fieldTakesPaste(_ facts: PasteFacts) -> Bool {
      guard facts.focused else {
        return false
      }
      return FocusCapture.isEditableTarget(
        role: facts.role,
        valueSettable: facts.valueSettable,
        hasInsertionPoint: facts.hasInsertionPoint,
        inWebArea: facts.inWebArea
      )
    }
  }
#endif

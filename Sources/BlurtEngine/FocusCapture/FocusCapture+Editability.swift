#if os(macOS)
  import AppKit
  import ApplicationServices

  // The "can this target accept a paste?" half of `FocusCapture`, split out of
  // `FocusCapture.swift` to stay within the lint file-length budget — the same
  // reason `DictationSession` is split across `+Commands`/`+Observation`/`+Pipeline`.
  //
  // Cohesive as its own file: everything here serves `KeyInjector`'s pre-paste
  // "no beep" guard, whereas `FocusCapture.swift` proper serves the press-time
  // context capture that primes the STT request.
  extension FocusCapture {
    /// AX roles a focused element reports when it accepts typed/pasted text.
    /// Includes `secureFieldRole`: a password field is a valid *paste* target even
    /// though its contents are never read (see `isSecureField`).
    private static let editableRoles: Set<String> = [
      "AXTextField", "AXTextArea", "AXComboBox", secureFieldRole, "AXSearchField",
    ]

    /// Pure decision: do these signals, read off a focused element, mean it accepts
    /// pasted text? The injector calls this just before a synthesized ⌘V — if it
    /// returns false the paste is skipped (so macOS doesn't beep into a non-editable
    /// target) and the transcript is left on the clipboard with a quiet "Copied"
    /// notice. The "is anything focused at all?" question is answered by the caller,
    /// which never gets this far without an element (see `hasEditableFocusedElement`).
    ///
    /// Requires a *positive* editability signal: a known text role, a settable value,
    /// or an insertion point. Anything else — a non-text control, an unknown role, or
    /// no readable role — is treated as not editable, so we copy rather than beep a
    /// ⌘V into a target that can't take it.
    ///
    /// AX-opaque apps — Electron editors (VS Code, Slack) and web browsers — can
    /// expose *none* of these signals even for a genuine text field, so this
    /// returns false for them too. The injector still pastes into those via a
    /// separate app-identity check (see `isAXOpaqueApp` / `KeyInjector.insert`),
    /// so the user's words aren't dropped to copy-only there.
    static func isEditableTarget(role: String?, valueSettable: Bool, hasInsertionPoint: Bool) -> Bool {
      if let role, editableRoles.contains(role) { return true }
      return valueSettable || hasInsertionPoint
    }

    /// Whether `app` is an Electron/Chromium-based app, detected by the bundled
    /// Electron framework. Such apps ship with their accessibility tree off, so even
    /// a focused text field exposes no editable AX signal and
    /// `hasEditableFocusedElement` reads them as non-editable. A native app with
    /// genuinely no editable focus bundles no such framework and correctly falls
    /// back to copy.
    static func isElectronApp(_ app: NSRunningApplication?) -> Bool {
      isElectronBundle(app?.bundleURL)
    }

    /// Pure decision behind `isElectronApp`: does the bundle at `bundleURL` ship the
    /// Electron framework? Split from the `NSRunningApplication` wrapper for the same
    /// reason as `isBrowserBundleID` — the detection is then unit-testable against a
    /// fixture bundle, instead of requiring an Electron app to be installed *and*
    /// running on the machine under test.
    ///
    /// Rebranded Electron apps rename the framework (Codex ships
    /// `Codex Framework.framework`), so the `ElectronAsarIntegrity` Info.plist key
    /// Electron's packager writes is checked as a fallback.
    static func isElectronBundle(_ bundleURL: URL?) -> Bool {
      guard let bundleURL else { return false }
      let electronFramework = bundleURL.appendingPathComponent(
        "Contents/Frameworks/Electron Framework.framework")
      if FileManager.default.fileExists(atPath: electronFramework.path) { return true }
      return Bundle(url: bundleURL)?.object(forInfoDictionaryKey: "ElectronAsarIntegrity") != nil
    }

    /// Bundle-identifier prefixes of known web browsers. Prefix-matched so channel
    /// variants classify with their stable siblings (`com.google.Chrome.beta`,
    /// `com.apple.SafariTechnologyPreview`).
    private static let browserBundleIDPrefixes: [String] = [
      "com.apple.Safari",  // Safari + Safari Technology Preview
      "com.google.Chrome",  // Chrome + Beta/Dev/Canary
      "org.chromium.Chromium",
      "com.microsoft.edgemac",  // Edge + Beta/Dev/Canary
      "com.brave.Browser",  // Brave + Beta/Nightly
      "com.operasoftware.Opera",
      "com.vivaldi.Vivaldi",
      "company.thebrowser.Browser",  // Arc
      "org.mozilla.firefox",
      "com.duckduckgo.macos.browser",
      "com.kagi.kagimacOS",  // Orion
    ]

    /// Pure decision behind `isBrowserApp`: does this bundle identifier belong to a
    /// known browser? Split from the `NSRunningApplication` wrapper so the
    /// classification is unit-testable without live running apps.
    static func isBrowserBundleID(_ bundleID: String?) -> Bool {
      guard let bundleID else { return false }
      return browserBundleIDPrefixes.contains { bundleID.hasPrefix($0) }
    }

    /// Whether `app` is a known web browser. Web content is AX-opaque in practice:
    /// Chromium builds its accessibility tree lazily (the first query after launch
    /// resolves only a bare `AXWebArea` with no editable signal), and even with the
    /// tree live, a `contenteditable` composer (ChatGPT's ProseMirror field) can
    /// surface as a generic group with no settable value. So "no editable signal"
    /// in a browser usually means "AX can't see the field," not "no field."
    static func isBrowserApp(_ app: NSRunningApplication?) -> Bool {
      isBrowserBundleID(app?.bundleIdentifier)
    }

    /// Whether `app` is AX-opaque — an Electron editor or a web browser — where a
    /// focused text field can expose no editable AX signal at all. These are the
    /// one case the injector still pastes into on a definite no-signal answer:
    /// dropping the user's words into a copy-only fallback there would be
    /// the worse mistake. The accepted trade-off is a rare ⌘V beep when such an
    /// app truly has nothing editable focused.
    static func isAXOpaqueApp(_ app: NSRunningApplication?) -> Bool {
      // String prefix checks first, whereas isElectronApp probes the disk
      // (FileManager.fileExists) — skip that I/O for the common case.
      isBrowserApp(app) || isElectronApp(app)
    }

    /// What Accessibility says about pasting into the focused element. Three
    /// answers, not two: an app can draw its own text view and show AX nothing at
    /// all, and that is "can't tell", not "nothing to paste into".
    enum FocusedEditability: Equatable {
      /// A text role, a settable value, or an insertion point.
      case editable
      /// AX answered, and what it shows takes no text: ⌘V would only beep.
      case notEditable
      /// AX couldn't answer. Measured on editors that draw their own text view
      /// (Sublime Text 4, Sublime Merge, Zed 1.23.2, where ⌘V lands): with the
      /// caret in a buffer the system-wide focus query fails with
      /// `kAXErrorCannotComplete`, or the focused element is the bare `AXWindow`
      /// with no value and no selection range.
      case cannotTell
    }

    /// Pure decision for a focus query that resolved no element: a query that
    /// couldn't complete can't tell; one that answered "nothing focused" (a native
    /// app with no focused control, the desktop) means nothing takes text.
    static func editability(ofFailedFocusQuery error: AXError) -> FocusedEditability {
      error == .cannotComplete ? .cannotTell : .notEditable
    }

    /// Pure decision for a focused element's signals: `isEditableTarget`'s
    /// positive signals, else a bare window — the element a custom-drawn editor
    /// reports — can't tell, and anything else takes no text.
    static func editability(
      role: String?, valueSettable: Bool, hasInsertionPoint: Bool
    ) -> FocusedEditability {
      if isEditableTarget(role: role, valueSettable: valueSettable, hasInsertionPoint: hasInsertionPoint) {
        return .editable
      }
      return role == windowRole ? .cannotTell : .notEditable
    }

    private static let windowRole = "AXWindow"

    /// Whether the system-wide focused element may accept pasted text right now:
    /// anything but a definite `.notEditable`. Read by `KeyInjector` (off the main
    /// actor, after it has activated the target app) just before pasting — the
    /// Accessibility *client* read APIs are thread-safe. Returns `true` whenever AX
    /// can't be consulted (process not trusted) or can't tell, so an unknowable
    /// state still attempts the paste — the injector's own trust check then
    /// handles the missing-permission case.
    nonisolated static func hasEditableFocusedElement() -> Bool {
      guard AXIsProcessTrusted() else { return true }
      return focusedEditability() != .notEditable
    }

    nonisolated private static func focusedEditability() -> FocusedEditability {
      let query = queryFocusedElement()
      guard let element = query.element else {
        // AX is trusted but resolved no focused element. Usually a native app with
        // nothing editable focused (Finder, the desktop, a button-only window),
        // where ⌘V only beeps; but a query that couldn't complete is AX failing,
        // not an answer. AX-opaque apps (Electron editors like VS Code/Slack, and
        // browsers before Chromium's lazy accessibility tree is built) also land
        // here, and the injector's app-identity check still pastes into those (see
        // `KeyInjector.insert` / `isAXOpaqueApp`).
        return editability(ofFailedFocusQuery: query.error)
      }

      // Same checked reader `captureFieldContext` uses for this attribute, so the
      // editability path and the secure-field path can't disagree about what a
      // misbehaving app's role reads as.
      let role = stringValue(element, kAXRoleAttribute)

      var settable = DarwinBoolean(false)
      let valueSettable =
        AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success
        && settable.boolValue

      // A readable selected-text *range* means the element has an insertion point —
      // the hallmark of a text input even when its value isn't reported settable.
      // Require the range to actually decode, not merely that the read succeeded: a
      // `.success` carrying a non-CFRange payload is not an insertion point, and this
      // signal is one of the two that can green-light a ⌘V on an unknown role.
      var rangeRef: CFTypeRef?
      let hasInsertionPoint =
        AXUIElementCopyAttributeValue(
          element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success
        && rangeRef.flatMap(axRange) != nil

      return editability(role: role, valueSettable: valueSettable, hasInsertionPoint: hasInsertionPoint)
    }
  }
#endif

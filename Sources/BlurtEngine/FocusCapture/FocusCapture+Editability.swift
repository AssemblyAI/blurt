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
    /// `inWebArea`: the element sits inside a web view's page, where the page's
    /// own markup decides what's editable — Meta's Muse reports its reply box,
    /// a content-editable area, as an `AXButton` (2026-11-04). That's web content
    /// as a browser's is, so it's pasted into as a browser's is, whatever app
    /// hosts the web view — apart from a focused link, which a page never edits.
    static func isEditableTarget(
      role: String?, valueSettable: Bool, hasInsertionPoint: Bool, inWebArea: Bool = false
    ) -> Bool {
      if let role, editableRoles.contains(role) { return true }
      return valueSettable || hasInsertionPoint || (inWebArea && role != "AXLink")
    }

    /// Whether `element` sits inside a web area, a few levels up at most.
    nonisolated static func isInWebArea(_ element: AXUIElement) -> Bool {
      var current: AXUIElement? = element
      for _ in 0..<12 {
        guard let level = current else { return false }
        if stringValue(level, kAXRoleAttribute) == "AXWebArea" { return true }
        current = elementValue(level, kAXParentAttribute)
      }
      return false
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

    /// Bundle-identifier prefixes of native editors that draw their own text view
    /// and expose no text element to Accessibility at all: with the caret in a
    /// buffer, the focused element is the bare `AXWindow` — no value, no selection
    /// range — or the system-wide query fails outright (`kAXErrorCannotComplete`).
    /// Measured on Sublime Text 4 (build 4215), Sublime Merge (build 2132, the
    /// commit-message box) and Zed 1.23.2; ⌘V lands in all three. Prefix-matched
    /// so channel variants classify with their stable siblings. Named rather than
    /// inferred from those AX answers: a native window with no focused control, or
    /// a busy app whose query times out, answers the same way, and pasting there
    /// beeps and then restores the clipboard over the user's words.
    private static let customDrawnEditorBundleIDPrefixes: [String] = [
      "com.sublimetext.",  // Sublime Text 3 + 4
      "com.sublimemerge",
      "dev.zed.Zed",  // Zed + Preview/Nightly
    ]

    /// Whether a bundle id is a known custom-drawn editor (Sublime Text, Sublime
    /// Merge, Zed). Neither a browser nor Electron, yet just as invisible to
    /// Accessibility — so without this it would read as "nothing editable
    /// focused" and every dictation would land on the clipboard instead of in
    /// the buffer. A pure check, split out for the same reason as
    /// `isBrowserBundleID`.
    static func isCustomDrawnEditorBundleID(_ bundleID: String?) -> Bool {
      guard let bundleID else { return false }
      return customDrawnEditorBundleIDPrefixes.contains { bundleID.hasPrefix($0) }
    }

    /// Whether `app` is AX-opaque — an Electron editor, a web browser, or a
    /// custom-drawn editor — where a focused text field can expose no editable AX
    /// signal at all. These are the one case the injector still pastes into on no
    /// signal: dropping the user's words into a copy-only fallback there would be
    /// the worse mistake. The accepted trade-off is a rare ⌘V beep when such an
    /// app truly has nothing editable focused.
    static func isAXOpaqueApp(_ app: NSRunningApplication?) -> Bool {
      // The bundle-id checks first, whereas isElectronApp probes the disk
      // (FileManager.fileExists) — skip that I/O for the common case.
      isAXOpaqueBundleID(app?.bundleIdentifier) || isElectronApp(app)
    }

    /// `isAXOpaqueApp`'s half that a bundle id settles: a browser or a
    /// custom-drawn editor.
    static func isAXOpaqueBundleID(_ bundleID: String?) -> Bool {
      isBrowserBundleID(bundleID) || isCustomDrawnEditorBundleID(bundleID)
    }

    /// Whether the system-wide focused element can accept pasted text right now.
    /// Read by `KeyInjector` (off the main actor, after it has activated the target
    /// app) just before pasting — the Accessibility *client* read APIs are
    /// thread-safe. Returns `true` whenever AX can't be consulted (process not
    /// trusted) or can't resolve a focused element, so an unknowable state still
    /// attempts the paste — the injector's own trust check then handles the
    /// missing-permission case.
    nonisolated static func hasEditableFocusedElement() -> Bool {
      guard let facts = focusFacts() else { return true }
      // AX trusted but nothing focused — a native app with nothing editable
      // (Finder, the desktop, a button-only window) — reads false: ⌘V there
      // only beeps. AX-opaque apps (Electron editors, browsers before
      // Chromium's lazy tree is built) can report the same, but the injector's
      // app-identity check still pastes into those (`isAXOpaqueApp`).
      return PasteTarget.fieldTakesPaste(facts)
    }

    /// The system-wide focused element's paste facts (`PasteFacts`), its app's
    /// half left empty; nil when Accessibility can't be consulted (not trusted).
    /// What `hasEditableFocusedElement` decides on, and what the paste fixtures
    /// record.
    ///
    /// On the paste path only what decides is read: the web-area walk — up to
    /// a dozen parent reads — runs only when nothing cheaper settled the
    /// answer, and the subrole (no part of the decision) not at all. The
    /// fixture recorder (`forRecording`) asks for every fact.
    nonisolated static func focusFacts(forRecording: Bool = false) -> PasteFacts? {
      guard AXIsProcessTrusted() else { return nil }
      guard let element = systemFocusedElement() else { return PasteFacts(focused: false) }
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
        AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success
        && rangeRef.flatMap(axRange) != nil
      let settled = isEditableTarget(role: role, valueSettable: valueSettable, hasInsertionPoint: hasInsertionPoint)
      return PasteFacts(
        focused: true, role: role, subrole: forRecording ? stringValue(element, kAXSubroleAttribute) : nil,
        valueSettable: valueSettable, hasInsertionPoint: hasInsertionPoint,
        inWebArea: (forRecording || !settled) && isInWebArea(element))
    }
  }
#endif

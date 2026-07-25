import AppKit
import ApplicationServices

// The "can this target accept a paste?" half of `FocusCapture`, split out of
// `FocusCapture.swift` to stay within the lint file-length budget — the same
// reason `DictationSession` is split across `+Commands`/`+Observation`/`+Pipeline`.
//
// Cohesive as its own file: everything here serves `KeyInjector`'s pre-paste
// "no beep" guard, whereas `FocusCapture.swift` proper serves the press-time
// context capture that primes the STT prompt.
extension FocusCapture {
  /// AX roles a focused element reports when it accepts typed/pasted text.
  /// Includes `secureFieldRole`: a password field is a valid *paste* target even
  /// though its contents are never read (see `isSecureField`).
  private static let editableRoles: Set<String> = [
    "AXTextField", "AXTextArea", "AXComboBox", secureFieldRole, "AXSearchField",
  ]

  /// Pure decision: does a focused element with these signals accept pasted text?
  /// The injector calls this just before a synthesized ⌘V — if it returns false the
  /// paste is skipped (so macOS doesn't beep into a non-editable target) and the
  /// transcript is left on the clipboard with a quiet "Copied" notice.
  ///
  /// Requires a *positive* editability signal: a known text role, a settable value,
  /// or an insertion point. Anything else — a non-text control, an unknown role, or
  /// no readable role — is treated as not editable, so we copy rather than beep a
  /// ⌘V into a target that can't take it.
  ///
  /// AX-opaque Electron editors (VS Code, Slack) expose *none* of these signals
  /// even for a genuine text field, so this returns false for them too — but the
  /// injector still pastes into those via a separate Electron-app check (see
  /// `isElectronApp` / `KeyInjector.insert`), so the user's words aren't dropped
  /// to copy-only there.
  static func isEditableTarget(
    hasFocusedElement: Bool, role: String?, valueSettable: Bool, hasInsertionPoint: Bool
  ) -> Bool {
    guard hasFocusedElement else { return false }
    if let role, editableRoles.contains(role) { return true }
    return valueSettable || hasInsertionPoint
  }

  /// Whether `app` is an Electron/Chromium-based app, detected by the bundled
  /// Electron framework. Such apps ship with their accessibility tree off, so even
  /// a focused text field exposes no editable AX signal and
  /// `hasEditableFocusedElement` reads them as non-editable. They're the one case
  /// the injector still pastes into on no signal (dropping the user's words into a
  /// copy-only fallback would be the worse mistake). A native app with genuinely no
  /// editable focus bundles no such framework and correctly falls back to copy.
  static func isElectronApp(_ app: NSRunningApplication?) -> Bool {
    guard let bundleURL = app?.bundleURL else { return false }
    let electronFramework = bundleURL.appendingPathComponent(
      "Contents/Frameworks/Electron Framework.framework")
    return FileManager.default.fileExists(atPath: electronFramework.path)
  }

  /// Whether the system-wide focused element can accept pasted text right now.
  /// Read by `KeyInjector` (off the main actor, after it has activated the target
  /// app) just before pasting — the Accessibility *client* read APIs are
  /// thread-safe. Returns `true` whenever AX can't be consulted (process not
  /// trusted) or can't resolve a focused element, so an unknowable state still
  /// attempts the paste — the injector's own trust check then handles the
  /// missing-permission case.
  nonisolated static func hasEditableFocusedElement() -> Bool {
    guard AXIsProcessTrusted() else { return true }

    guard let element = systemFocusedElement() else {
      // AX is trusted but reports no focused element — e.g. a native app frontmost
      // with nothing editable focused (Finder, the desktop, a button-only window).
      // Posting ⌘V there only beeps, so treat it as non-editable and copy instead.
      // AX-opaque Electron apps (VS Code, Slack) also expose no focused element
      // here, but the injector's Electron-app check still pastes into those (see
      // `KeyInjector.insert` / `isElectronApp`).
      return false
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

    return isEditableTarget(
      hasFocusedElement: true, role: role, valueSettable: valueSettable,
      hasInsertionPoint: hasInsertionPoint)
  }
}

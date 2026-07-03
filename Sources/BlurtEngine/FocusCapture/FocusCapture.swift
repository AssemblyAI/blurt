import AppKit
import ApplicationServices

struct CapturedFocus: Sendable {
  let pid: pid_t
  let processName: String?
}

enum FocusCapture {
  @MainActor
  static func captureFrontmost() -> CapturedFocus? {
    guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
    return CapturedFocus(
      pid: app.processIdentifier,
      processName: app.localizedName
    )
  }

  static func runningApp(for captured: CapturedFocus) -> NSRunningApplication? {
    NSRunningApplication(processIdentifier: captured.pid)
  }

  /// Accessibility-derived priming read from the system-wide focused UI element
  /// at dictation start (see `TranscriptionContext`). Every field is
  /// best-effort: any signal that can't be read is `nil`, and a fully-empty
  /// result simply means less context, never an error.
  struct FocusedFieldContext: Sendable {
    /// Text immediately preceding the insertion point ("prior chunk context").
    let priorText: String?
    /// The text currently selected in the focused field — the dictation will
    /// replace it, so it primes the model on what the utterance is about.
    let selectedText: String?
    /// The focused window's title — a dense topic hint.
    let windowTitle: String?
    /// A short label for the focused field ("To", "Search", "Message").
    let fieldLabel: String?

    static let empty = FocusedFieldContext(
      priorText: nil, selectedText: nil, windowTitle: nil, fieldLabel: nil)
  }

  /// Reads window title, field label, and up to `maxPriorChars` of text before
  /// the cursor from the focused UI element in a single Accessibility traversal.
  ///
  /// Returns `.empty` whenever nothing can be read — the process lacks
  /// Accessibility trust or no element is focused. Each field is independently
  /// best-effort. Requires the same Accessibility permission the app already
  /// holds for paste injection, so it adds no new prompt.
  ///
  /// Secure text fields (password inputs) are detected by role and never have
  /// their contents read, so a typed password — selected or not — can't leak
  /// into the STT prompt.
  ///
  /// Deliberately `nonisolated`: each read below is a synchronous cross-process
  /// IPC round trip into the frontmost app, and an unresponsive app blocks the
  /// calling thread until the AX messaging timeout. On the main actor that froze
  /// the overlay and menu bar right at hotkey press; callers run this off-main
  /// (the AX *client* read APIs are thread-safe — see `systemFocusedElement`).
  nonisolated static func captureFieldContext(maxPriorChars: Int = 320, maxSelectedChars: Int = 320)
    -> FocusedFieldContext
  {
    guard AXIsProcessTrusted() else { return .empty }
    guard let element = systemFocusedElement() else { return .empty }

    // Don't read the value of a password field into the prompt.
    let isSecure = isSecureFieldRole(stringValue(element, kAXRoleAttribute))
    let prior = isSecure ? nil : priorText(of: element, maxChars: maxPriorChars)
    // The selected range's text (empty when there's no selection). Capped like
    // prior text so a huge highlight can't dominate the prompt budget.
    let selected = isSecure ? nil : selectedText(of: element, maxChars: maxSelectedChars)
    return FocusedFieldContext(
      priorText: prior,
      selectedText: selected,
      windowTitle: clip(windowTitle(of: element), to: 120),
      fieldLabel: clip(fieldLabel(of: element), to: 80))
  }

  /// Cap on each cross-process AX round trip this process makes. An unresponsive
  /// frontmost app costs a read this long, not the ~6 s system default; the
  /// context capture is best-effort priming, so partial answers beat waiting.
  private static let axMessagingTimeoutSeconds: Float = 1

  /// The system-wide focused UI element, or `nil` when none is resolvable
  /// (process not trusted, or nothing focused). The Accessibility *client* read
  /// APIs are thread-safe, so this serves both the off-main context capture
  /// and the injector's off-main editability check.
  private nonisolated static func systemFocusedElement() -> AXUIElement? {
    let system = AXUIElementCreateSystemWide()
    // Setting the timeout on the system-wide element applies it process-wide
    // (per AXUIElement.h), bounding this focused-element lookup AND every later
    // read — including ones on *other* element refs a per-element timeout would
    // miss (the window element behind `windowTitle`, the editability probes).
    AXUIElementSetMessagingTimeout(system, axMessagingTimeoutSeconds)
    var focusedRef: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedRef)
        == .success,
      let focusedRef
    else { return nil }
    // CFTypeRef → AXUIElement is a guaranteed CF downcast; `as?` warns
    // "always succeeds" (an error under -warnings-as-errors), so force-cast.
    // swiftlint:disable:next force_cast
    return (focusedRef as! AXUIElement)
  }

  /// The insertion point (UTF-16 location of the selected range) of `element`,
  /// or `nil` when it exposes no readable selection.
  private nonisolated static func caretLocation(of element: AXUIElement) -> Int? {
    var rangeRef: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef)
        == .success,
      let rangeRef
    else { return nil }
    var cfRange = CFRange()
    // swiftlint:disable:next force_cast
    guard AXValueGetValue(rangeRef as! AXValue, .cfRange, &cfRange) else { return nil }
    return cfRange.location
  }

  /// Up to `maxChars` of text immediately preceding the insertion point, or
  /// `nil` when the element exposes no readable text before the cursor.
  private nonisolated static func priorText(of element: AXUIElement, maxChars: Int) -> String? {
    // Insertion point = the location of the (possibly empty) selected range.
    let caret = caretLocation(of: element) ?? -1

    // Prefer the parameterized "string for range" so we read only the slice we
    // need (cheap even in huge documents) rather than the whole field value.
    if caret > 0 {
      let start = max(0, caret - maxChars)
      var sliceRange = CFRange(location: start, length: caret - start)
      if let axRange = AXValueCreate(.cfRange, &sliceRange) {
        var sliceRef: CFTypeRef?
        if AXUIElementCopyParameterizedAttributeValue(
          element, kAXStringForRangeParameterizedAttribute as CFString, axRange, &sliceRef)
          == .success, let slice = sliceRef as? String, !slice.isEmpty
        {
          return slice
        }
      }
    }

    // Fallback: read the full value and clip to the caret (or the tail).
    return priorSlice(full: stringValue(element, kAXValueAttribute) ?? "", caret: caret, maxChars: maxChars)
  }

  /// Up to `maxChars` of selected text, or `nil` when the element exposes no
  /// readable selection. Uses the selected range plus the parameterized
  /// string-for-range attribute first so a huge highlight does not copy the full
  /// selection across Accessibility IPC before being clipped locally.
  private nonisolated static func selectedText(of element: AXUIElement, maxChars: Int) -> String? {
    var rangeRef: CFTypeRef?
    if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef)
      == .success, let rangeRef
    {
      var selectedRange = CFRange()
      // swiftlint:disable:next force_cast
      if AXValueGetValue(rangeRef as! AXValue, .cfRange, &selectedRange),
        selectedRange.length > 0
      {
        selectedRange.length = min(selectedRange.length, maxChars)
        if let axRange = AXValueCreate(.cfRange, &selectedRange) {
          var sliceRef: CFTypeRef?
          if AXUIElementCopyParameterizedAttributeValue(
            element, kAXStringForRangeParameterizedAttribute as CFString, axRange, &sliceRef)
            == .success, let slice = sliceRef as? String
          {
            return clip(slice.trimmedNonEmpty(), to: maxChars)
          }
        }
      }
    }

    return clip(stringValue(element, kAXSelectedTextAttribute), to: maxChars)
  }

  /// The title of the window containing the focused element, if exposed.
  private nonisolated static func windowTitle(of element: AXUIElement) -> String? {
    guard let window = elementValue(element, kAXWindowAttribute) else { return nil }
    return stringValue(window, kAXTitleAttribute)
  }

  /// A short, human-meaningful label for the field, chosen by priority from the
  /// attributes the focused element exposes.
  private nonisolated static func fieldLabel(of element: AXUIElement) -> String? {
    selectLabel(
      placeholder: stringValue(element, kAXPlaceholderValueAttribute),
      description: stringValue(element, kAXDescriptionAttribute),
      title: stringValue(element, kAXTitleAttribute),
      roleDescription: stringValue(element, kAXRoleDescriptionAttribute))
  }

  /// Reads a `String`-valued AX attribute, returning `nil` for missing,
  /// non-string, or blank values.
  private nonisolated static func stringValue(_ element: AXUIElement, _ attribute: String) -> String? {
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
      let value = ref as? String
    else { return nil }
    return value.trimmedNonEmpty()
  }

  /// Reads an `AXUIElement`-valued AX attribute (e.g. the containing window).
  private nonisolated static func elementValue(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
      let ref
    else { return nil }
    // swiftlint:disable:next force_cast
    return (ref as! AXUIElement)
  }

  // MARK: - Editable-target detection (for the injector's "no beep" guard)

  /// AX roles a focused element reports when it accepts typed/pasted text.
  /// Includes `secureFieldRole`: a password field is a valid *paste* target even
  /// though its contents are never read (see `isSecureFieldRole`).
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

    var roleRef: CFTypeRef?
    let role =
      AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success
      ? roleRef as? String : nil

    var settable = DarwinBoolean(false)
    let valueSettable =
      AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success
      && settable.boolValue

    // A readable selected-text *range* means the element has an insertion point —
    // the hallmark of a text input even when its value isn't reported settable.
    var rangeRef: CFTypeRef?
    let hasInsertionPoint =
      AXUIElementCopyAttributeValue(
        element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success

    return isEditableTarget(
      hasFocusedElement: true, role: role, valueSettable: valueSettable,
      hasInsertionPoint: hasInsertionPoint)
  }

  // MARK: - Pure helpers (no Accessibility I/O — unit-testable in isolation)

  /// The AX role password inputs report. `captureFieldContext` never reads the
  /// prior/selected text of a field with this role into the STT prompt, so a
  /// typed password can't leak. Independent of editability: the same role is in
  /// `editableRoles`, so a password field still *receives* the paste.
  static let secureFieldRole = "AXSecureTextField"

  /// Pure decision behind the password-redaction guard in `captureFieldContext`:
  /// does this focused-element role mean its contents must never be read?
  static func isSecureFieldRole(_ role: String?) -> Bool {
    role == secureFieldRole
  }

  /// Picks the most descriptive field label in priority order
  /// (placeholder → description → title → role description), skipping blanks.
  /// Placeholder/description tend to be the most meaningful; role description
  /// ("text entry area") is the generic last resort.
  static func selectLabel(
    placeholder: String?, description: String?, title: String?, roleDescription: String?
  ) -> String? {
    for candidate in [placeholder, description, title, roleDescription] {
      if let value = candidate.trimmedNonEmpty() { return value }
    }
    return nil
  }

  /// The up-to-`maxChars` slice of `full` ending at `caret`. `caret` is a
  /// **UTF-16 offset** (the domain AX selected-text ranges use — see
  /// `caretLocation`), so it is resolved through the UTF-16 view rather than
  /// counted in `Character`s, which diverge as soon as the text holds emoji or
  /// other surrogate pairs. A caret outside the string — or one that doesn't
  /// land on a character boundary — falls back to the tail of the whole value.
  /// Returns `nil` when the resulting slice is empty.
  static func priorSlice(full: String, caret: Int, maxChars: Int) -> String? {
    guard !full.isEmpty else { return nil }
    let upto: Substring
    if caret >= 0, caret <= full.utf16.count,
      let index = full.utf16.index(
        full.utf16.startIndex, offsetBy: caret, limitedBy: full.utf16.endIndex)?
        .samePosition(in: full)
    {
      upto = full[..<index]
    } else {
      upto = full[...]
    }
    let clipped = String(upto.suffix(maxChars))
    return clipped.isEmpty ? nil : clipped
  }

  /// Caps `text` at `maxChars` characters (used to bound window titles / labels
  /// so an oddly long one can't dominate the prompt budget).
  static func clip(_ text: String?, to maxChars: Int) -> String? {
    guard let text, text.count > maxChars else { return text }
    return String(text.prefix(maxChars))
  }
}

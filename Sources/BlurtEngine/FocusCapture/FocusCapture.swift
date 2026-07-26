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
  /// Secure text fields (password inputs) are detected by role **or** subrole and
  /// never have their contents read, so a typed password — selected or not — can't
  /// leak into the STT prompt. The check fails closed: an unreadable role is
  /// treated as secure, since it can't be shown not to be.
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

    // Don't read the value of a password field into the prompt. Fails *closed*:
    // an unreadable role (AX timeout against a busy app, a non-string value from a
    // buggy one) means we can't prove the field isn't secure, so treat it as
    // secure. The cost is losing priming for an already-degraded app; the cost of
    // failing open is a password in an outbound API request — and, with developer
    // mode on, in `dictations.jsonl`.
    let role = stringValue(element, kAXRoleAttribute)
    let isSecure = role == nil || isSecureField(role: role, subrole: stringValue(element, kAXSubroleAttribute))
    // `visibleTextOrNil` collapses an all-invisible read (e.g. Google Docs' lone
    // U+200B before the caret) to nil so it can't masquerade as real prior text.
    let prior = isSecure ? nil : visibleTextOrNil(priorText(of: element, maxChars: maxPriorChars))
    // The selected range's text (empty when there's no selection). Capped like
    // prior text so a huge highlight can't dominate the prompt budget.
    let selected = isSecure ? nil : visibleTextOrNil(selectedText(of: element, maxChars: maxSelectedChars))
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

  // Internal, not private: `hasEditableFocusedElement` in
  // FocusCapture+Editability.swift calls it from another file.
  /// The system-wide focused UI element, or `nil` when none is resolvable
  /// (process not trusted, or nothing focused). The Accessibility *client* read
  /// APIs are thread-safe, so this serves both the off-main context capture
  /// and the injector's off-main editability check.
  nonisolated static func systemFocusedElement() -> AXUIElement? {
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
    return axElement(focusedRef)
  }

  // MARK: - Checked CF downcasts
  //
  // AX attribute values arrive as CFTypeRef from *other apps'* accessibility
  // implementations, so a misbehaving app returning the wrong CF type must read
  // as "nothing readable" (nil), never flow onward mistyped. CF bridging makes
  // `as?` a compile-time "always succeeds" warning (an error under
  // -warnings-as-errors), so the runtime check is CFGetTypeID; after it the
  // force-cast below each guard is provably safe — these two helpers are the
  // only force_cast sites in the repo. Internal (not private) so the unit tests
  // can exercise both arms without Accessibility trust.

  /// `ref` as an `AXUIElement`, or `nil` when it's some other CF type.
  nonisolated static func axElement(_ ref: CFTypeRef) -> AXUIElement? {
    guard CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
    // swiftlint:disable:next force_cast
    return (ref as! AXUIElement)
  }

  /// `ref` decoded as an `AXValue`-wrapped `CFRange` (the selected-text-range
  /// payload), or `nil` when it's some other CF type or a non-range `AXValue`
  /// (`AXValueGetValue` checks the payload type and refuses a mismatch).
  nonisolated static func axRange(_ ref: CFTypeRef) -> CFRange? {
    guard CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
    // swiftlint:disable:next force_cast
    let value = ref as! AXValue
    var range = CFRange()
    guard AXValueGetValue(value, .cfRange, &range) else { return nil }
    return range
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
    return axRange(rangeRef)?.location
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

    // Fallback: read the full value and clip to the caret (or the tail). Read it
    // RAW — `caret` is a UTF-16 offset into the untrimmed value, so a trimmed
    // string would be indexed with offsets that no longer refer to it.
    return priorSlice(full: rawStringValue(element, kAXValueAttribute) ?? "", caret: caret, maxChars: maxChars)
  }

  /// Up to `maxChars` of selected text, or `nil` when the element exposes no
  /// readable selection. Uses the selected range plus the parameterized
  /// string-for-range attribute first so a huge highlight does not copy the full
  /// selection across Accessibility IPC before being clipped locally.
  private nonisolated static func selectedText(of element: AXUIElement, maxChars: Int) -> String? {
    var rangeRef: CFTypeRef?
    if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef)
      == .success, let rangeRef, var selectedRange = axRange(rangeRef), selectedRange.length > 0
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

  // Internal for the same reason as `systemFocusedElement`: the editability path in
  // FocusCapture+Editability.swift reads the role through it.
  /// Reads a `String`-valued AX attribute, returning `nil` for missing,
  /// non-string, or blank values. Trims, which is what the *label-ish* attributes
  /// want (role, title, placeholder, description). Do **not** use it for
  /// `kAXValueAttribute` when a caret offset will index the result — see
  /// `rawStringValue`.
  nonisolated static func stringValue(_ element: AXUIElement, _ attribute: String) -> String? {
    rawStringValue(element, attribute)?.trimmedNonEmpty()
  }

  /// Reads a `String`-valued AX attribute **verbatim** — no trimming, so a
  /// caret offset taken from the same element still indexes it correctly.
  ///
  /// `kAXSelectedTextRange` locations are UTF-16 offsets into the element's
  /// *original* value. Trimming shifts every offset past a leading whitespace run
  /// and shortens the string, so slicing a trimmed value with an untrimmed caret
  /// silently returns the wrong text (or falls back to the whole tail, which
  /// destroys the trailing-whitespace signal `withLeadingSeparator` reads).
  private nonisolated static func rawStringValue(_ element: AXUIElement, _ attribute: String) -> String? {
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
      let value = ref as? String
    else { return nil }
    return value
  }

  /// Reads an `AXUIElement`-valued AX attribute (e.g. the containing window).
  private nonisolated static func elementValue(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
      let ref
    else { return nil }
    return axElement(ref)
  }

  // MARK: - Pure helpers (no Accessibility I/O — unit-testable in isolation)

  /// The AX role password inputs report. `captureFieldContext` never reads the
  /// prior/selected text of a field with this role into the STT prompt, so a
  /// typed password can't leak. Independent of editability: the same role is in
  /// `editableRoles`, so a password field still *receives* the paste.
  static let secureFieldRole = "AXSecureTextField"

  /// Pure decision behind the password-redaction guard in `captureFieldContext`:
  /// do this focused element's role/subrole mean its contents must never be read?
  static func isSecureField(role: String?, subrole: String?) -> Bool {
    // AppKit ships both NSAccessibilitySecureTextFieldRole and
    // NSAccessibilitySecureTextFieldSubrole (both the same string), and an element
    // may report a generic `AXTextField` role while expressing secure-ness only
    // through its subrole — browser password inputs and custom secure fields are
    // the population that does this. Checking role alone misses them entirely.
    role == secureFieldRole || subrole == secureFieldRole
  }

  /// Collapses an AX text read that carries no *visible* content to `nil`.
  ///
  /// Google Docs (and some other web editors) expose the text before the caret as
  /// a lone U+200B ZERO WIDTH SPACE — invisible, not real content, yet crucially
  /// *not* `Character.isWhitespace`. Left as-is, `KeyInjector.withLeadingSeparator`
  /// reads it as substantive preceding text that doesn't end in whitespace and
  /// prepends a stray separator space on every dictation. Treating an
  /// entirely-invisible read as "nothing readable here" (`nil`) instead routes the
  /// field into the same-window separator fallback like any other
  /// Accessibility-opaque editor (see `KeyInjector.separatorBasis`).
  ///
  /// "Invisible" means every scalar is a default-ignorable code point (zero-width
  /// spaces, joiners, bidi marks, BOM, …). Regular whitespace (space/tab/newline)
  /// is deliberately preserved: a caret that already follows real whitespace must
  /// stay non-`nil` so the separator logic adds no extra space.
  static func visibleTextOrNil(_ text: String?) -> String? {
    guard let text else { return nil }
    let hasVisible = text.contains { character in
      !character.unicodeScalars.allSatisfy { $0.properties.isDefaultIgnorableCodePoint }
    }
    return hasVisible ? text : nil
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

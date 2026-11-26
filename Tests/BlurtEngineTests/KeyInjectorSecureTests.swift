#if os(macOS)
  import AppKit
  import Testing

  @testable import BlurtEngine

  /// #348: what `KeyInjector` leaves on the clipboard for a dictation into a
  /// password field. The words are still left for a paste by hand when the
  /// paste can't land, but as the secret they are — `SystemClipboard` maps
  /// `concealed` onto nspasteboard.org's markers and an expiry, which
  /// `SystemClipboardTests` covers against the real pasteboard.
  @Suite("KeyInjector.insert: password fields")
  struct KeyInjectorSecureTests {
    @Test("an ordinary dictation's leave-behind is kept as is for the paste by hand")
    func noEditableTargetLeavesPlainWords() async throws {
      let clip = FakeClipboard(string: "user-clipboard")
      let injector = KeyInjector(
        pasteSettleDuration: .zero, postPaste: { _ in true }, hasEditableTarget: { false }, clipboard: clip
      )

      await #expect(throws: BlurtError.noEditableTarget) {
        try await injector.insert("dictated text", after: nil, windowTitle: nil, security: .ordinary)
      }
      #expect(clip.isKeptForHandPaste)
      #expect(!clip.isConcealed)
    }

    /// #348: a password field's words that can't be pasted are still left for
    /// the paste by hand, but as the secret they are — never as an ordinary
    /// copy a clipboard manager keeps.
    @Test("a password field's words left on the clipboard are concealed, on every degraded path")
    func secureLeaveBehindIsConcealed() async throws {
      let noTarget = FakeClipboard(string: "user-clipboard")
      let unfocused = KeyInjector(
        pasteSettleDuration: .zero, postPaste: { _ in true }, hasEditableTarget: { false }, clipboard: noTarget
      )
      await #expect(throws: BlurtError.noEditableTarget) {
        try await unfocused.insert("hunter2", after: nil, windowTitle: nil, security: .secure)
      }
      #expect(noTarget.string == "hunter2")
      #expect(noTarget.isConcealed)

      // The keystroke couldn't be built: the same leave-behind, by the third path.
      let noKeystroke = FakeClipboard(string: "user-clipboard")
      let unposted = KeyInjector(pasteSettleDuration: .zero, postPaste: { _ in false }, clipboard: noKeystroke)
      await #expect(throws: BlurtError.targetAppLost) {
        try await unposted.insert("hunter2", after: nil, windowTitle: nil, security: .secure)
      }
      #expect(noKeystroke.string == "hunter2")
      #expect(noKeystroke.isConcealed)
    }

    @Test("a password field's paste is concealed too, and the restore after it is not")
    func securePasteIsConcealedUntilRestored() async throws {
      let clip = FakeClipboard(string: "user-clipboard")
      let seen = ValueBox<Bool>(false)
      let injector = KeyInjector(
        pasteSettleDuration: .zero,
        postPaste: { _ in
          seen.value = clip.isConcealed
          return true
        },
        clipboard: clip
      )

      try await injector.insert("hunter2", after: nil, windowTitle: nil, security: .secure)
      await injector.pendingSettle?.value

      #expect(seen.value)
      #expect(clip.string == "user-clipboard")
      #expect(!clip.isConcealed)
    }
  }

  /// A field whose security the press-time read couldn't establish
  /// (`TargetSecurity.unknown`): concealed where a password field could hide —
  /// an AX-opaque app — and an ordinary copy everywhere else, where "unknown"
  /// means nothing was focused at all.
  extension KeyInjectorSecureTests {
    @Test("an unknown field's leave-behind outside an AX-opaque app stays an ordinary copy")
    func unknownFieldInReadableAppIsPlain() async throws {
      let clip = FakeClipboard(string: "user-clipboard")
      let injector = KeyInjector(
        pasteSettleDuration: .zero,
        postPaste: { _ in true },
        hasEditableTarget: { false },
        isAXOpaqueApp: { _ in false },
        clipboard: clip
      )

      await #expect(throws: BlurtError.noEditableTarget) {
        try await injector.insert("dictated text", after: nil, windowTitle: nil, security: .unknown)
      }
      #expect(clip.string == "dictated text")
      #expect(clip.isKeptForHandPaste)
      #expect(!clip.isConcealed)
    }

    @Test(
      "in an AX-opaque app an unknown field's words are concealed like a password's, an ordinary one's are not",
      arguments: [(TargetSecurity.unknown, true), (.secure, true), (.ordinary, false)]
    )
    func opaqueAppConcealsUnknownField(security: TargetSecurity, concealed: Bool) async throws {
      // The paste itself: the words on the clipboard while ⌘V is read.
      let pasted = FakeClipboard(string: "user-clipboard")
      // Starts as the wrong answer, so a ⌘V that's never read fails the check.
      let seen = ValueBox<Bool>(!concealed)
      let pasting = KeyInjector(
        pasteSettleDuration: .zero,
        postPaste: { _ in
          seen.value = pasted.isConcealed
          return true
        },
        hasEditableTarget: { false },
        isAXOpaqueApp: { _ in true },
        clipboard: pasted
      )
      try await pasting.insert("hunter2", after: nil, windowTitle: nil, security: security)
      await pasting.pendingSettle?.value
      #expect(seen.value == concealed)
      #expect(pasted.string == "user-clipboard")

      // The keystroke couldn't be built: the words are left for a paste by hand.
      let left = FakeClipboard(string: "user-clipboard")
      let unposted = KeyInjector(
        pasteSettleDuration: .zero,
        postPaste: { _ in false },
        hasEditableTarget: { false },
        isAXOpaqueApp: { _ in true },
        clipboard: left
      )
      await #expect(throws: BlurtError.targetAppLost) {
        try await unposted.insert("hunter2", after: nil, windowTitle: nil, security: security)
      }
      #expect(left.string == "hunter2")
      #expect(left.isConcealed == concealed)
    }

    /// The activation-failure path judges the pinned target itself: there is
    /// no frontmost app to ask about yet, and the target is where the field was.
    @Test("a target that won't activate is judged for opacity on its own", arguments: [true, false])
    func activationFailureJudgesTheTarget(opaque: Bool) async throws {
      let focus = try liveTargetFocus()
      let judged = ValueBox<pid_t?>(nil)
      let clip = FakeClipboard(string: "user-clipboard")
      let injector = KeyInjector(
        pasteSettleDuration: .zero,
        postPaste: { _ in true },
        activateTarget: { _ in false },
        isAXOpaqueApp: { app in
          judged.value = app?.processIdentifier
          return opaque
        },
        clipboard: clip
      )
      await injector.setTarget(focus)

      await #expect(throws: BlurtError.targetAppLost) {
        try await injector.insert("hunter2", after: nil, windowTitle: nil, security: .unknown)
      }
      #expect(judged.value == focus.pid)
      #expect(clip.string == "hunter2")
      #expect(clip.isConcealed == opaque)
    }
  }
#endif

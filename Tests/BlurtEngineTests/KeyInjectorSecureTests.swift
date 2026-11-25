#if os(macOS)
  import Foundation
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
        try await injector.insert("dictated text")
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
        try await unfocused.insert("hunter2", secure: true)
      }
      #expect(noTarget.string == "hunter2")
      #expect(noTarget.isConcealed)

      // The keystroke couldn't be built: the same leave-behind, by the third path.
      let noKeystroke = FakeClipboard(string: "user-clipboard")
      let unposted = KeyInjector(pasteSettleDuration: .zero, postPaste: { _ in false }, clipboard: noKeystroke)
      await #expect(throws: BlurtError.targetAppLost) {
        try await unposted.insert("hunter2", secure: true)
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

      try await injector.insert("hunter2", secure: true)
      await injector.pendingSettle?.value

      #expect(seen.value)
      #expect(clip.string == "user-clipboard")
      #expect(!clip.isConcealed)
    }
  }
#endif

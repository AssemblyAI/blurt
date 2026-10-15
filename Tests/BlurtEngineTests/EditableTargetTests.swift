#if os(macOS)
  import ApplicationServices
  import Testing

  @testable import BlurtEngine

  @Suite("FocusCapture.isEditableTarget")
  struct EditableTargetTests {
    @Test("a known text role is editable")
    func textRole() {
      #expect(
        FocusCapture.isEditableTarget(
          role: "AXTextArea", valueSettable: false, hasInsertionPoint: false))
    }

    @Test("a secure (password) field is still a paste target despite prompt redaction")
    func secureFieldIsEditable() {
      // Redaction (never read a password into the STT prompt) and editability
      // (the paste may land there) are independent: dictating into a password
      // field must type, even though its contents are never captured.
      #expect(
        FocusCapture.isEditableTarget(
          role: FocusCapture.secureFieldRole, valueSettable: false, hasInsertionPoint: false))
    }

    @Test("a settable value is editable even with an unknown role")
    func settableValue() {
      #expect(
        FocusCapture.isEditableTarget(
          role: "AXUnknown", valueSettable: true, hasInsertionPoint: false))
    }

    @Test("an insertion point is editable even with an unknown role")
    func insertionPoint() {
      #expect(
        FocusCapture.isEditableTarget(
          role: nil, valueSettable: false, hasInsertionPoint: true))
    }

    @Test("a non-text control with no editable signal is not editable")
    func nonEditableControl() {
      #expect(
        !FocusCapture.isEditableTarget(
          role: "AXButton", valueSettable: false, hasInsertionPoint: false))
    }

    @Test("an unknown role with no editable signal is not editable (copy, don't beep)")
    func unknownRoleWithoutSignalCopies() {
      // A focused element that reports an unrecognized role and exposes no settable
      // value or insertion point isn't a text target — copy rather than beep a ⌘V
      // into it. (AX-opaque apps — Electron editors and browsers — also land here,
      // but are pasted into via the injector's separate app-identity check, not
      // this signal test.)
      #expect(
        !FocusCapture.isEditableTarget(
          role: "AXWebArea", valueSettable: false, hasInsertionPoint: false))
    }

    @Test("a focused element with an unreadable role is not editable (copy, don't beep)")
    func nilRoleWithoutSignalCopies() {
      #expect(
        !FocusCapture.isEditableTarget(
          role: nil, valueSettable: false, hasInsertionPoint: false))
    }
  }

  /// The third answer: AX that can't tell pastes rather than copies, which is
  /// what lets editors that draw their own text view (Sublime Text, Zed) take a
  /// dictation without being named.
  @Suite("FocusCapture.editability")
  struct FocusedEditabilityTests {
    @Test("a focus query that couldn't complete can't tell")
    func cannotComplete() {
      #expect(FocusCapture.editability(ofFailedFocusQuery: .cannotComplete) == .cannotTell)
    }

    @Test("a focus query that found nothing focused means nothing takes text")
    func nothingFocused() {
      #expect(FocusCapture.editability(ofFailedFocusQuery: .noValue) == .notEditable)
      #expect(FocusCapture.editability(ofFailedFocusQuery: .failure) == .notEditable)
    }

    @Test("a bare window with no text signal can't tell")
    func bareWindow() {
      #expect(
        FocusCapture.editability(role: "AXWindow", valueSettable: false, hasInsertionPoint: false) == .cannotTell)
    }

    @Test("a text signal is editable, a window's included")
    func editableSignals() {
      #expect(
        FocusCapture.editability(role: "AXTextArea", valueSettable: false, hasInsertionPoint: false) == .editable)
      #expect(FocusCapture.editability(role: "AXWindow", valueSettable: false, hasInsertionPoint: true) == .editable)
    }

    @Test("any other element without a text signal takes no text", arguments: ["AXButton", "AXGroup", nil])
    func otherElements(role: String?) {
      #expect(FocusCapture.editability(role: role, valueSettable: false, hasInsertionPoint: false) == .notEditable)
    }
  }

  @Suite("noTarget phase + overlay mapping")
  struct NoTargetPhaseTests {
    @Test("noTarget is terminal")
    func terminal() {
      #expect(PipelinePhase.noTarget.isTerminal)
    }

    @Test("noTarget maps to the quiet overlay state, not an error")
    func overlayMapping() {
      #expect(PipelinePhase.noTarget.overlayState == .noTarget)
    }
  }
#endif

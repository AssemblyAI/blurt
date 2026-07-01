import Testing

@testable import BlurtEngine

@Suite("FocusCapture.isEditableTarget")
struct EditableTargetTests {
  @Test("no focused element is never editable")
  func noFocusedElement() {
    #expect(
      !FocusCapture.isEditableTarget(
        hasFocusedElement: false, role: "AXTextField", valueSettable: true, hasInsertionPoint: true))
  }

  @Test("a known text role is editable")
  func textRole() {
    #expect(
      FocusCapture.isEditableTarget(
        hasFocusedElement: true, role: "AXTextArea", valueSettable: false, hasInsertionPoint: false))
  }

  @Test("a settable value is editable even with an unknown role")
  func settableValue() {
    #expect(
      FocusCapture.isEditableTarget(
        hasFocusedElement: true, role: "AXUnknown", valueSettable: true, hasInsertionPoint: false))
  }

  @Test("an insertion point is editable even with an unknown role")
  func insertionPoint() {
    #expect(
      FocusCapture.isEditableTarget(
        hasFocusedElement: true, role: nil, valueSettable: false, hasInsertionPoint: true))
  }

  @Test("a non-text control with no editable signal is not editable")
  func nonEditableControl() {
    #expect(
      !FocusCapture.isEditableTarget(
        hasFocusedElement: true, role: "AXButton", valueSettable: false, hasInsertionPoint: false))
  }

  @Test("an unknown role with no editable signal is not editable (copy, don't beep)")
  func unknownRoleWithoutSignalCopies() {
    // A focused element that reports an unrecognized role and exposes no settable
    // value or insertion point isn't a text target — copy rather than beep a ⌘V
    // into it. (AX-opaque Electron editors, which also land here, are pasted into
    // via the injector's separate Electron-app check, not this signal test.)
    #expect(
      !FocusCapture.isEditableTarget(
        hasFocusedElement: true, role: "AXWebArea", valueSettable: false, hasInsertionPoint: false))
  }

  @Test("a focused element with an unreadable role is not editable (copy, don't beep)")
  func nilRoleWithoutSignalCopies() {
    #expect(
      !FocusCapture.isEditableTarget(
        hasFocusedElement: true, role: nil, valueSettable: false, hasInsertionPoint: false))
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

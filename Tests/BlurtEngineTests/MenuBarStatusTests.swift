import Testing

@testable import BlurtEngine

/// The menu bar status item's state is a pure function of the pipeline phase.
/// Lifting that mapping into the engine lets `swift test` cover it (the SwiftUI
/// shell that renders it has no test target).
@Suite("PipelinePhase → MenuBarStatus")
struct MenuBarStatusTests {
  /// One row per `PipelinePhase` case. A table rather than a `@Test` apiece (the
  /// precedent `DictationKeyGateTests` sets) so that adding a phase makes the
  /// missing row visible here instead of leaving the mapping silently unpinned —
  /// which is how `.noTarget` went uncovered. `.failed` keeps its own test below,
  /// since its mapping encodes a deliberate policy rather than a coarser icon.
  static let projections: [(phase: PipelinePhase, expected: MenuBarStatus)] = [
    (.recording, .recording),
    (.transcribing, .transcribing),
    (.idle, .idle),
    // The mic is still opening, so the coarse indicator rests at idle rather
    // than claiming "recording" — the one thing `.connecting` exists to prevent.
    (.connecting, .idle),
    // Injection happens silently; the indicator rests at idle through the brief
    // paste rather than showing a distinct state.
    (.injecting, .idle),
    (.cancelled, .idle),
    // The completed-paste notice lives on the pill; the menu bar stays idle.
    (.pasted, .idle),
    // Likewise the "copied to clipboard" notice — pill only.
    (.noTarget, .idle),
  ]

  @Test("each phase projects to its menu bar status", arguments: projections)
  func phaseProjectsToMenuBarStatus(phase: PipelinePhase, expected: MenuBarStatus) {
    #expect(phase.menuBarStatus == expected)
  }

  @Test func failedMapsToIdle() {
    // Unlike the overlay pill (which flashes red), the menu bar deliberately
    // doesn't surface the transient error — so a handled failure reads as idle,
    // and the icon can't get stranded on a state nothing transitions out of (the
    // pill's error revert is timer-driven, not a follow-up phase).
    #expect(PipelinePhase.failed(.targetAppLost).menuBarStatus == .idle)
  }
}

/// The status item's glyph and VoiceOver label per state. Owned in the engine
/// (mirroring `OverlayUIState.accessibilityLabel`) so the wording lives in one
/// unit-tested place; the SwiftUI shell reads these verbatim, so a silent edit
/// would otherwise ship an unannounced regression.
@Suite("MenuBarStatus presentation")
struct MenuBarStatusPresentationTests {
  @Test func symbolNames() {
    // A stylized "B" at rest, filling in while recording — the same idle→fill
    // idiom the mic glyphs used — and the waveform while transcribing.
    #expect(MenuBarStatus.idle.symbolName == "b.circle")
    #expect(MenuBarStatus.recording.symbolName == "b.circle.fill")
    #expect(MenuBarStatus.transcribing.symbolName == "waveform")
  }

  @Test func accessibilityLabels() {
    #expect(MenuBarStatus.idle.accessibilityLabel == "Blurt — idle")
    #expect(MenuBarStatus.recording.accessibilityLabel == "Blurt — recording")
    #expect(MenuBarStatus.transcribing.accessibilityLabel == "Blurt — transcribing")
  }
}

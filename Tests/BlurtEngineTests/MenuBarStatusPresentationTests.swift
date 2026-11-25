import Testing

@testable import BlurtEngine

/// The status item's glyph and VoiceOver label per state. Owned in the engine
/// (mirroring `OverlayUIState.accessibilityLabel`) so the wording lives in one
/// unit-tested place; the SwiftUI shell reads these verbatim, so a silent edit
/// would otherwise ship an unannounced regression.
@Suite("MenuBarStatus presentation")
struct MenuBarStatusPresentationTests {
  @Test
  func symbolNames() {
    // A stylized "B" at rest, filling in while recording — the same idle→fill
    // idiom the mic glyphs used — and the waveform while transcribing.
    #expect(MenuBarStatus.idle.symbolName == "b.circle")
    #expect(MenuBarStatus.recording.symbolName == "b.circle.fill")
    #expect(MenuBarStatus.transcribing.symbolName == "waveform")
    #expect(MenuBarStatus.recordingAudio.symbolName == "record.circle")
  }

  @Test
  func accessibilityLabels() {
    #expect(MenuBarStatus.idle.accessibilityLabel == "Blurt — idle")
    #expect(MenuBarStatus.recording.accessibilityLabel == "Blurt — recording")
    #expect(MenuBarStatus.transcribing.accessibilityLabel == "Blurt — transcribing")
    #expect(MenuBarStatus.recordingAudio.accessibilityLabel == "Blurt — recording mic and Mac audio")
  }

  @Test("a Record-button recording shows when no dictation is on, and only while capturing (#345)")
  func recordingAudioFoldsIn() {
    #expect(MenuBarStatus.idle.showing(recordingAudio: true) == .recordingAudio)
    #expect(MenuBarStatus.idle.showing(recordingAudio: false) == .idle)
    // A dictation during the recording is what the glyph shows until it ends.
    #expect(MenuBarStatus.recording.showing(recordingAudio: true) == .recording)
    #expect(MenuBarStatus.transcribing.showing(recordingAudio: true) == .transcribing)
  }
}

import Foundation
import Testing

@testable import BlurtEngine

/// The pill while and after a read plays, and when each cue pair reloads after
/// the output route changes.
@Suite("Read-aloud pill and cues")
struct ReadAloudPillAndCueTests {
  /// A phase, with the pill it shows while a read plays (nil: leave the read's
  /// pill) and once a read ends.
  private struct Row {
    let phase: PipelinePhase
    let whileSpeaking: OverlayUIState?
    let afterSpeech: OverlayUIState

    init(_ phase: PipelinePhase, _ whileSpeaking: OverlayUIState?, _ afterSpeech: OverlayUIState) {
      (self.phase, self.whileSpeaking, self.afterSpeech) = (phase, whileSpeaking, afterSpeech)
    }
  }

  private static let phases: [Row] = [
    Row(.idle, nil, .idle),
    Row(.connecting, .connecting, .connecting),
    Row(.recording, .recording, .recording),
    Row(.transcribing, nil, .processing),
    Row(.injecting, nil, .processing),
    Row(.pasted, nil, .idle),
    Row(.noTarget, nil, .idle),
    Row(.cancelled, nil, .idle),
    Row(.handedBack("Explain."), nil, .idle),
    Row(.failed(.apiKeyMissing), nil, .idle),
  ]

  @Test("while a read plays, only a new capture takes the pill; when it ends, no old notice replays")
  func pillAroundARead() {
    for row in Self.phases {
      let (phase, whileSpeaking, afterSpeech) = (row.phase, row.whileSpeaking, row.afterSpeech)
      #expect(phase.overlayState(whileSpeaking: true) == whileSpeaking, "\(phase) while speaking")
      #expect(phase.overlayState(whileSpeaking: false) == phase.overlayState, "\(phase) with no read")
      #expect(phase.overlayStateAfterSpeech == afterSpeech, "\(phase) after a read")
    }
  }

  @Test("read-aloud's cues reload at once when nothing is capturing")
  func readCuesReloadWhenIdle() {
    var schedule = CueReprimeSchedule()
    #expect(schedule.routeChanged() == .init(dictation: false, readAloud: true))
    // Dictation's still waits for a press or a terminal phase.
    #expect(schedule.phase(.connecting) == .init(dictation: true, readAloud: false))
    #expect(schedule.phase(.recording) == .none)
  }

  @Test("mid-capture, read-aloud's cues wait for the capture's end; dictation's reload at the next press")
  func readCuesWaitForTheCapture() {
    var schedule = CueReprimeSchedule()
    _ = schedule.phase(.connecting)
    _ = schedule.phase(.recording)
    #expect(schedule.routeChanged() == .none)
    #expect(schedule.phase(.transcribing) == .none)
    #expect(schedule.phase(.pasted) == .init(dictation: true, readAloud: true))
    #expect(schedule.phase(.idle) == .none)
  }

  @Test("with no route change, nothing reloads")
  func nothingPending() {
    var schedule = CueReprimeSchedule()
    for row in Self.phases { #expect(schedule.phase(row.phase) == .none) }
  }

  @Test("the views' key decisions: extra rows, the only dictating key, whether read-aloud does anything")
  func bindingsViewHelpers() {
    let defaults = TriggerKeyBindings(boundKeyCode: 54, choicesRaw: "", modesRaw: "", sharedModeRaw: "")
    #expect(defaults.extraKeys == [.leftOption])
    #expect(defaults.isOnlyDictatingKey(.rightCommand))
    #expect(defaults.readsOrAsks)
    #expect(!defaults.asks)
    let asking = TriggerKeyBindings(
      boundKeyCode: 54, choicesRaw: #"{"58":"","61":"current","59":"ask"}"#, modesRaw: "", sharedModeRaw: "")
    #expect(asking.extraKeys == [.rightOption, .leftControl])
    #expect(!asking.isOnlyDictatingKey(.rightCommand))
    #expect(asking.readsOrAsks)
    #expect(asking.asks)
    let silent = TriggerKeyBindings(boundKeyCode: 54, choicesRaw: #"{"58":""}"#, modesRaw: "", sharedModeRaw: "")
    #expect(!silent.readsOrAsks)
  }
}

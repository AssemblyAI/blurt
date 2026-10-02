import BlurtEngine
import Foundation
import Testing

@testable import BlurtiOSCore

@Suite("Voice state")
struct VoiceStateTests {
  private func snapshot(_ state: PhaseSnapshot.State, level: Double = 0, message: String? = nil) -> PhaseSnapshot {
    PhaseSnapshot(state: state, message: message, level: level, at: Date())
  }

  @Test("ready and idle: the circle, still, nothing else")
  func idle() {
    let state = VoiceState(snapshot: snapshot(.idle), isReady: true)
    #expect(state.ring == .still)
    #expect(state.glyph == nil)
    #expect(!state.isRecording && !state.isWorking && !state.isNotice && !state.dimmed && !state.canCancel)
    #expect(state.accessibilityLabel == "Dictate")
    #expect(state.accessibilityValue == "")
  }

  @Test("the mic coming up and the words being made sweep the ring; recording is the meter, ring still")
  func inFlight() {
    let connecting = VoiceState(snapshot: snapshot(.connecting), isReady: true)
    #expect(connecting.ring == .sweeping && connecting.isWorking && connecting.canCancel && !connecting.isRecording)
    let recording = VoiceState(snapshot: snapshot(.recording, level: 0.62), isReady: true)
    #expect(recording.ring == .still && recording.isRecording && recording.isWorking && recording.level == 0.62)
    #expect(recording.accessibilityLabel == "Stop dictation")
    let processing = VoiceState(snapshot: snapshot(.processing), isReady: true)
    #expect(processing.ring == .sweeping && processing.isWorking && !processing.isRecording)
  }

  @Test("the notices: green ring for the words landing, a clipboard when copied, orange and an exclamation on error")
  func notices() {
    let pasted = VoiceState(snapshot: snapshot(.pasted), isReady: true)
    #expect(pasted.ring == .solid(.ok) && pasted.glyph == nil && pasted.isNotice && !pasted.canCancel)
    let copied = VoiceState(snapshot: snapshot(.copied), isReady: true)
    #expect(copied.ring == .solid(.ok) && copied.glyph == .clipboard)
    let error = VoiceState(snapshot: snapshot(.error, message: "The microphone didn't start."), isReady: true)
    #expect(error.ring == .solid(.error) && error.glyph == .exclamation)
    #expect(error.accessibilityValue == "The microphone didn't start.")
    #expect(VoiceState(snapshot: snapshot(.error), isReady: true).accessibilityValue == "Dictation failed.")
  }

  @Test("not ready: dimmed, no meter, no glyph, no sweep; a tap starts Blurt")
  func notReady() {
    for phase in [PhaseSnapshot.State.idle, .connecting, .recording, .processing, .copied] {
      let state = VoiceState(snapshot: snapshot(phase, level: 0.5), isReady: false)
      #expect(state.dimmed && !state.isRecording && !state.isWorking && state.glyph == nil)
      #expect(state.ring != .sweeping)
      #expect(state.accessibilityLabel == "Start Blurt")
    }
  }

  @Test("the app's overlay state maps onto the same phases; no target is copied")
  func overlay() {
    #expect(VoiceState(overlay: .noTarget, windowOpen: true, level: 0).phase == .copied)
    #expect(VoiceState(overlay: .error(message: "x"), windowOpen: true, level: 0).message == "x")
    #expect(VoiceState(overlay: .recording, windowOpen: true, level: 0.4).level == 0.4)
    #expect(VoiceState(overlay: .idle, windowOpen: false, level: 0).dimmed)
    #expect(VoiceState(overlay: .processing, windowOpen: true, level: 0).ring == .sweeping)
  }
}

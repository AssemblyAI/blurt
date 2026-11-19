import BlurtEngine
import Foundation
import Testing

@testable import BlurtiOSCore

/// The line under the mic: every row of DESIGN.md's status-line table, the
/// countdown and patience arithmetic, and which row wins when two apply.
@Suite("Voice notice")
struct VoiceNoticeTests {
  private static let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
  private static let launch = UUID()
  /// The app listening, a beat ago.
  private static let ready = ListeningState(
    launchID: launch, sequence: 1, window: .open, micLive: true, writtenAt: now.addingTimeInterval(-1))

  private var now: Date { Self.now }

  private func record(
    window: ListeningState.Window, micLive: Bool = false, reason: FailureReason? = nil, age: TimeInterval = 1
  ) -> ListeningState {
    ListeningState(
      launchID: Self.launch, sequence: 2, window: window, micLive: micLive, reason: reason,
      writtenAt: now.addingTimeInterval(-age))
  }

  private func phase(
    _ state: PhaseSnapshot.State, message: String? = nil, reason: FailureReason? = nil, age: TimeInterval = 0,
    recordingFor: TimeInterval? = nil
  ) -> PhaseSnapshot {
    PhaseSnapshot(
      state: state, message: message, level: 0, at: now.addingTimeInterval(-age), reason: reason,
      recordingSince: recordingFor.map { now.addingTimeInterval(-$0) })
  }

  private func line(
    fullAccess: Bool = true, state: ListeningState? = VoiceNoticeTests.ready, snapshot: PhaseSnapshot = .idle,
    heldError: PhaseSnapshot? = nil, handshake: VoiceNotice.Handshake = .idle,
    autoRelease: TimeInterval = SyncSTTLimits.autoReleaseSeconds
  ) -> VoiceNotice.Line? {
    VoiceNotice.line(
      for: VoiceNotice.Input(
        hasFullAccess: fullAccess, state: state, snapshot: snapshot, heldError: heldError, handshake: handshake,
        now: now, autoReleaseSeconds: autoRelease))
  }

  private func expected(_ text: String, _ tap: VoiceNotice.Tap) -> VoiceNotice.Line {
    VoiceNotice.Line(text: text, tapOpens: tap)
  }

  private var tapToOpen: VoiceNotice.Line { expected("Tap to open Blurt", .hop(.sessionOff)) }

  @Test("no Full Access: the note is the key, whatever else is true")
  func fullAccess() {
    let note = expected("Allow Full Access in Settings", .setup)
    #expect(line(fullAccess: false) == note)
    #expect(line(fullAccess: false, state: nil, snapshot: phase(.copied)) == note)
    #expect(line(fullAccess: false, snapshot: phase(.error, reason: .micDenied), handshake: .unready(.noKey)) == note)
    #expect(line(fullAccess: false, snapshot: phase(.recording, recordingFor: 1190)) == note)
  }

  @Test("no record, a closed record, or a lapsed lease: tap to open Blurt")
  func notListening() {
    #expect(line(state: nil) == tapToOpen)
    #expect(line(state: record(window: .closed)) == tapToOpen)
    #expect(line(state: record(window: .closing)) == tapToOpen)
    #expect(line(state: record(window: .closed, reason: .sessionOff)) == tapToOpen)
    let lapsed = record(window: .open, micLive: true, age: ListeningState.lease + 1)
    #expect(line(state: lapsed) == expected("Tap to open Blurt", .hop(.suspended)))
  }

  @Test("a press that expired unanswered, or an app that lapsed, as the handshake saw it, over a ready record")
  func unreadyHandshake() {
    #expect(line(handshake: .unready(.unanswered)) == expected("Tap to open Blurt", .hop(.unanswered)))
    #expect(line(handshake: .unready(.suspended)) == expected("Tap to open Blurt", .hop(.suspended)))
    #expect(line(handshake: .unready(.sessionOff)) == tapToOpen)
  }

  @Test("interrupted: paused by a call, and the tap hops rather than buzzing")
  func interrupted() {
    let paused = expected("Mic paused by a call — tap to open Blurt", .hop(.interrupted))
    #expect(line(state: record(window: .interrupted, reason: .interrupted)) == paused)
    #expect(line(state: record(window: .interrupted)) == paused)
    #expect(line(handshake: .unready(.interrupted)) == paused)
    #expect(line(snapshot: phase(.error, reason: .interrupted)) == paused)
  }

  @Test("the window needs the foreground, or is opening: open Blurt to start")
  func opening() {
    #expect(
      line(state: record(window: .closed, reason: .needsForeground))
        == expected("Open Blurt to start", .hop(.needsForeground)))
    #expect(line(state: record(window: .opening)) == expected("Open Blurt to start", .hop(.opening)))
    #expect(line(handshake: .unready(.opening)) == expected("Open Blurt to start", .hop(.opening)))
  }

  @Test("the setup reasons name what to allow or add")
  func setup() {
    #expect(
      line(state: record(window: .closed, reason: .micDenied))
        == expected("Allow the microphone in Settings", .hop(.micDenied)))
    #expect(line(state: record(window: .closed, reason: .noKey)) == expected("Add your API key in Blurt", .hop(.noKey)))
    #expect(
      line(state: record(window: .closed, reason: .noConsent)) == expected("Open Blurt to continue", .hop(.noConsent)))
  }

  @Test("ready and idle says nothing; neither do the mic coming up, the words landing, or a fresh in-flight phase")
  func wordless() {
    #expect(line() == nil)
    #expect(line(snapshot: phase(.connecting)) == nil)
    #expect(line(snapshot: phase(.pasted)) == nil)
    #expect(line(snapshot: phase(.processing, age: 1)) == nil)
    #expect(line(snapshot: phase(.recording, recordingFor: 10)) == nil)
    #expect(line(snapshot: phase(.recording)) == nil)
  }

  @Test("a press in flight is the deadline's business; so are an owned dictation, a foreign one and a stop")
  func inFlight() {
    #expect(line(handshake: .pressing) == nil)
    #expect(line(state: record(window: .closed), handshake: .pressing) == nil)
    #expect(line(state: nil, handshake: .owned) == nil)
    #expect(line(state: nil, handshake: .foreign) == nil)
    #expect(line(state: record(window: .closed, reason: .noKey), handshake: .foreign) == nil)
    #expect(line(state: nil, handshake: .stopping) == nil)
  }

  @Test("still transcribing after 3 s of processing, not at 3 s, and whoever is pressing or lapsed")
  func processing() {
    let still = expected("Still transcribing…", .buzz)
    let patience = VoiceNotice.transcribingPatience
    #expect(line(snapshot: phase(.processing, age: patience)) == nil)
    #expect(line(snapshot: phase(.processing, age: patience + 0.01)) == still)
    #expect(line(snapshot: phase(.processing, age: 60)) == still)
    #expect(line(snapshot: phase(.processing, age: 4), handshake: .stopping) == still)
    #expect(line(state: nil, snapshot: phase(.processing, age: 4)) == still)
  }

  @Test(
    "a notice beats the handshake: an error over an unanswered press, the countdown over a refusal, an error mid-press"
  )
  func noticeOverHandshake() {
    let silent = expected("The mic went silent — tap to open Blurt", .hop(.micSilent))
    #expect(line(snapshot: phase(.error, reason: .micSilent), handshake: .unready(.unanswered)) == silent)
    #expect(
      line(state: nil, snapshot: phase(.error, reason: .micSilent), handshake: .unready(.unanswered)) == silent)
    let tenLeft = expected("10 s left", .press)
    let nearRelease = phase(.recording, recordingFor: 50)
    #expect(line(snapshot: nearRelease, handshake: .unready(.unanswered), autoRelease: 60) == tenLeft)
    #expect(line(snapshot: nearRelease, handshake: .unready(.sessionOff), autoRelease: 60) == tenLeft)
    #expect(line(snapshot: nearRelease, handshake: .unready(.suspended), autoRelease: 60) == tenLeft)
    #expect(line(snapshot: phase(.error, reason: .micSilent), handshake: .pressing) == silent)
    #expect(
      line(snapshot: phase(.error, reason: .micBusy), handshake: .pressing)
        == expected("Another app has the mic — tap to open Blurt", .hop(.micBusy)))
    #expect(
      line(snapshot: phase(.error, reason: .network), handshake: .pressing)
        == expected("No connection — tap to try again", .press))
  }

  @Test("the held error: its row over an idle snapshot until the next press, never over a phase in flight")
  func heldError() {
    let held = phase(.error, reason: .micSilent, age: 5)
    let silent = expected("The mic went silent — tap to open Blurt", .hop(.micSilent))
    #expect(line(heldError: held) == silent)
    #expect(line(snapshot: phase(.idle, age: 1), heldError: held) == silent)
    #expect(line(state: nil, heldError: held) == silent)
    #expect(line(state: record(window: .closed), heldError: held) == silent)
    #expect(line(heldError: held, handshake: .unready(.unanswered)) == silent)
    let words = "Audio capture failed: the input went away."
    #expect(line(heldError: phase(.error, message: words)) == expected(words, .press))
    #expect(line(state: nil, heldError: phase(.error, message: words)) == expected(words, .hop(.sessionOff)))
    #expect(line(heldError: phase(.error)) == nil)
    #expect(line(state: nil, heldError: phase(.error)) == tapToOpen)
    #expect(line(fullAccess: false, heldError: held) == expected("Allow Full Access in Settings", .setup))
    // A held snapshot that is not an error is nothing to hold.
    #expect(line(heldError: phase(.copied)) == nil)
    // In flight, the live phase is the line's business.
    #expect(line(snapshot: phase(.connecting), heldError: held) == nil)
    #expect(line(snapshot: phase(.recording, recordingFor: 10), heldError: held) == nil)
    #expect(
      line(snapshot: phase(.recording, recordingFor: 50), heldError: held, autoRelease: 60)
        == expected("10 s left", .press))
    #expect(line(snapshot: phase(.processing, age: 1), heldError: held) == nil)
    #expect(
      line(snapshot: phase(.processing, age: 4), heldError: held) == expected("Still transcribing…", .buzz))
    #expect(line(snapshot: phase(.pasted), heldError: held) == nil)
    #expect(line(snapshot: phase(.copied), heldError: held) == expected("Copied to the clipboard", .press))
    #expect(
      line(snapshot: phase(.error, reason: .network), heldError: held)
        == expected("No connection — tap to try again", .press))
  }

  @Test("the countdown: from 30 s before the auto-release, up to the second, never below zero")
  func countdown() {
    let release = SyncSTTLimits.autoReleaseSeconds
    #expect(release == 1195)
    #expect(line(snapshot: phase(.recording, recordingFor: release - 30.5)) == nil)
    #expect(line(snapshot: phase(.recording, recordingFor: release - 30)) == expected("30 s left", .press))
    #expect(line(snapshot: phase(.recording, recordingFor: release - 29.5)) == expected("30 s left", .press))
    #expect(line(snapshot: phase(.recording, recordingFor: release - 15.2)) == expected("16 s left", .press))
    #expect(line(snapshot: phase(.recording, recordingFor: release - 1)) == expected("1 s left", .press))
    #expect(line(snapshot: phase(.recording, recordingFor: release)) == expected("0 s left", .press))
    #expect(line(snapshot: phase(.recording, recordingFor: release + 3)) == expected("0 s left", .press))
    #expect(line(snapshot: phase(.recording, recordingFor: 50), autoRelease: 60) == expected("10 s left", .press))
    #expect(
      line(snapshot: phase(.recording, recordingFor: 50), handshake: .owned, autoRelease: 60)
        == expected("10 s left", .press))
  }

  @Test("copied: a notice over the resting line, until the dwell settles it")
  func copied() {
    let copied = expected("Copied to the clipboard", .press)
    #expect(line(snapshot: phase(.copied)) == copied)
    #expect(line(state: record(window: .closed), snapshot: phase(.copied)) == copied)
    #expect(line(state: nil, snapshot: phase(.copied), handshake: .unready(.unanswered)) == copied)
  }

  @Test(
    "an error with a reason shows that reason's line; without one, the engine's words; with neither, the readiness line"
  )
  func error() {
    #expect(
      line(snapshot: phase(.error, reason: .micSilent))
        == expected("The mic went silent — tap to open Blurt", .hop(.micSilent)))
    #expect(
      line(snapshot: phase(.error, reason: .micBusy))
        == expected("Another app has the mic — tap to open Blurt", .hop(.micBusy)))
    #expect(
      line(snapshot: phase(.error, reason: .mediaReset))
        == expected("Audio was reset — tap to open Blurt", .hop(.mediaReset)))
    #expect(line(snapshot: phase(.error, reason: .network)) == expected("No connection — tap to try again", .press))
    #expect(line(state: nil, snapshot: phase(.error, reason: .sessionOff)) == tapToOpen)
    let words = "Audio capture failed: the input went away."
    #expect(line(snapshot: phase(.error, message: words)) == expected(words, .press))
    #expect(
      line(state: record(window: .closed), snapshot: phase(.error, message: words))
        == expected(words, .hop(.sessionOff)))
    #expect(
      line(snapshot: phase(.error, message: words), handshake: .unready(.unanswered))
        == expected(words, .hop(.unanswered)))
    #expect(line(snapshot: phase(.error)) == nil)
    #expect(line(state: nil, snapshot: phase(.error)) == tapToOpen)
  }

  @Test("every reason has a sentence and a tap, and the handshake's refusal shows them")
  func everyReason() {
    for reason in FailureReason.allCases {
      #expect(!reason.line.isEmpty)
      #expect(line(handshake: .unready(reason)) == expected(reason.line, VoiceNotice.tap(for: reason)))
      #expect(VoiceNotice.tap(for: reason) == (reason == .network ? .press : .hop(reason)))
    }
  }

  @Test("the numbers are the table's, and the auto-release is the engine's")
  func numbers() {
    #expect(VoiceNotice.transcribingPatience == 3)
    #expect(VoiceNotice.countdownWindow == 30)
    let input = VoiceNotice.Input(hasFullAccess: true, state: nil, snapshot: .idle, handshake: .idle, now: now)
    #expect(input.autoReleaseSeconds == SyncSTTLimits.autoReleaseSeconds)
    #expect(input.heldError == nil)
  }
}

import Foundation
import Testing
import UIKit

@testable import BlurtiOSCore

/// The keyboard model driven through thousands of random event sequences —
/// every finger, phase, ack, record, host and lifecycle event the real
/// keyboard sees, in any order — with the invariants that must hold after
/// every one of them checked each time. Seeded, so a failure names the
/// sequence that made it. This is the "nothing is ever left stale" check: a
/// state the model can be driven into and not out of shows up here as a
/// broken invariant. The event table is in `KeyboardModelFuzzTests+Drive.swift`.
@Suite("Keyboard model: random transition sequences", .serialized)
@MainActor
struct KeyboardModelFuzzTests {
  /// One event the fuzz can send. Phases come as the app would publish
  /// them, named for the dictation the handshake knows or for another; acks
  /// answer the last command; the rest are the keyboard's own entry points.
  enum Event: CaseIterable {
    case micDown, micUp, cancel, swipeOffOrb
    case phaseIdle, phaseConnecting, phaseRecording, phaseProcessing, phasePasted, phaseCopied, phaseError
    case answerConnecting, answerError
    case ackStarted, ackBusy, ackNotListening, ackEnded, deadline
    case appNotListening, appListening, stateClosed, stateInterrupted, stateLapsed
    case beginTerm, cancelTerm, saveTerm, termType, termSpace, termDelete, termReturn
    case selectWord, selectOther, clearSelection, addSelected, dismissSelected
    case appeared, disappeared, appearedNoAccess, hostLeaving, contextChanged
    case resultFresh, resultStale, resultForOther
    case hostTyped, hostMovedCursor
  }

  /// A tiny deterministic generator (SplitMix64), so a run is repeatable.
  struct Random {
    var state: UInt64
    mutating func next() -> UInt64 {
      state &+= 0x9E37_79B9_7F4A_7C15
      var z = state
      z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
      z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
      return z ^ (z >> 31)
    }
    mutating func pick<T>(_ items: [T]) -> T { items[Int(next() % UInt64(items.count))] }
    mutating func coin() -> Bool { next() % 2 == 0 }
  }

  @Test(
    "ten thousand random events never leave the model in a stale or contradictory state", arguments: [1, 2, 3, 4, 5])
  func fuzz(seed: UInt64) {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    var random = Random(state: seed &* 7919)
    let rig = KeyboardRig()
    let (model, proxy, commands) = (rig.model, rig.proxy, rig.commands)
    model.appeared()
    var trace: [Event] = []
    for step in 0..<2000 {
      let event = random.pick(Event.allCases)
      trace.append(event)
      let context = "seed \(seed) step \(step) after \(event); last 12: \(trace.suffix(12))"
      // Read before the event: the handshake as it stood, whether words were
      // in flight, whether a word is highlighted for the term field to open
      // over, and which commands had gone out.
      let before = model.handshake
      let stateBefore = model.snapshot.state
      let seededTerm = KeyboardModel.termCandidate(from: proxy.selectedText) != nil
      let sentBefore = commands.sent
      drive(rig, event, &random)
      for command in commands.sent.dropFirst(sentBefore.count) {
        // The same command again is the handshake's resend: nothing new.
        guard !sentBefore.contains(where: { $0.id == command.id }) else { continue }
        switch command.kind {
        case .press:
          // Never two of our starting commands in flight: a press goes out
          // only with no press of ours unanswered and no stop out.
          #expect(before.pressID == nil && before.stopID == nil, "a press over a press or stop out — \(context)")
        case .release, .cancel:
          // Never a release or cancel without the dictation's id once it is known.
          if let known = before.dictationID {
            #expect(command.dictationID == known, "an ending for the wrong dictation — \(context)")
          }
        }
        // The user's words are never thrown away behind their back. A cancel
        // over a recording or a transcription is only ever theirs to ask for:
        // the × key, or the term field opened over a highlighted word (whose
        // words would land on the word being fixed). Leaving the screen, the
        // host leaving, a swipe across the orb, the plain + — none may drop speech.
        if command.kind == .cancel, stateBefore == .recording || stateBefore == .processing {
          let asked = event == .cancel || (event == .beginTerm && seededTerm)
          #expect(asked, "words dropped: cancel in \(stateBefore) by \(event) — \(context)")
        }
      }
      check(model, proxy, commands, after: event, context)
    }
  }

  /// What must be true after every event, whatever came before.
  private func check(
    _ model: KeyboardModel, _ proxy: FakeProxy, _ commands: KeyboardRig.Commands, after event: Event, _ context: String
  ) {
    // The term field's bookkeeping lives and dies with the field.
    let fieldOpen = model.termDraft != nil
    #expect((model.termHostBaseline != nil) == fieldOpen, "term baseline vs field — \(context)")
    #expect((model.termHostBaselineAfter != nil) == fieldOpen, "term baseline-after vs field — \(context)")
    #expect(model.termDraftFromSelection == nil || fieldOpen, "seed outlives the field — \(context)")
    // The term is a name or two: capitalised to start and after a space,
    // then as typed; its spaces are one between words, never a run and
    // never first.
    if let draft = model.termDraft {
      #expect(model.termWantsUppercase == (draft.isEmpty || draft.last == " "), "term case rule — \(context)")
      #expect(!draft.hasPrefix(" ") && !draft.contains("  "), "a term's spaces — \(context)")
    } else {
      #expect(!model.termWantsUppercase, "case wanted with no field — \(context)")
    }
    // The chip and its dismissal never both stand.
    #expect(model.dismissedSelection == nil || model.selectedTerm == nil, "chip and dismissal both up — \(context)")
    if let term = model.selectedTerm {
      let candidate = KeyboardModel.termCandidate(from: proxy.selectedText)
      #expect(model.hasFullAccess, "chip without Full Access — \(context)")
      #expect(candidate?.caseInsensitiveCompare(term) == .orderedSame, "chip for a word not highlighted — \(context)")
      if model.selectedTermIsKnown {
        #expect(
          SharedStore.keyTerms.contains { $0.caseInsensitiveCompare(term) == .orderedSame },
          "known chip for an unknown word — \(context)")
      }
    } else {
      #expect(!model.selectedTermIsKnown, "known without a chip — \(context)")
    }
    // The voice picture never shows what the app can't be doing; an error's
    // exclamation is the one glyph that shows over a dimmed key.
    let state = model.voiceState
    if !state.isReady {
      #expect(!state.isRecording && !state.canCancel, "in-flight picture with no app — \(context)")
      #expect(state.glyph == nil || state.glyph == .exclamation, "a notice's glyph with no app — \(context)")
    }
    // A latched gate is only ever held by the handshake: our press out, a
    // dictation we own or latched onto, or our stop out — never over nothing.
    if !model.gate.isIdle {
      let held = !model.handshake.isIdle && model.handshake.unreadyReason == nil
      #expect(held, "gate latched with nothing of ours in flight — \(context)")
    }
    // Not ready, the line says why. With a press, a dictation or a stop in
    // the handshake's hands the line may be nil — that is the deadline's
    // business and the picture's; from rest or refused it never is.
    switch model.handshake.state {
    case .pressing, .owned, .foreign, .stopping:
      break
    case .idle, .unready:
      if !model.isReady { #expect(model.statusLine != nil, "not ready with no line — \(context)") }
    }
    #expect(
      commands.sent.allSatisfy { $0.keyboard == KeyboardProcess.id && $0.controllerID == model.controllerID },
      "command from another keyboard — \(context)")
    // A result is never left in the store once it was inserted here.
    if let pending = SharedStore.read(DictationResult.self, forKey: BlurtShared.Key.result) {
      #expect(pending.id != model.lastResultID, "inserted result still in the store — \(context)")
    }
  }

  @Test("from any state, an appearance is a clean keyboard that can dictate")
  func recovers() {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    var random = Random(state: 42)
    let rig = KeyboardRig()
    let (model, commands) = (rig.model, rig.commands)
    // Hands-free off: a tap must be the press here, not the stop of one the
    // appearance started.
    SharedStore.autoDictate = false
    model.appeared()
    // A controller in a window for the hop to walk to the application —
    // attached only around the tap: an appearance would read Full Access off
    // it, and outside an extension there is none.
    let (hops, window) = rig.capturingHops()
    defer { window.isHidden = true }
    let controller = model.controller
    model.controller = nil
    for round in 0..<200 {
      for _ in 0..<25 { drive(rig, random.pick(Event.allCases), &random) }
      appDies(rig, hops, controller: controller, round: round, &random)
      // The keyboard goes away; whatever it had out runs to its deadline;
      // the app ends whatever dictation was still in flight (its own end, or
      // the watchdog's) and it comes back with the app idle and listening.
      model.disappeared()
      drive(rig, .deadline, &random)
      if let dictation = model.handshake.dictationID { model.apply(snapshot(.pasted, dictation: dictation)) }
      SharedStore.write(snapshot(.idle), forKey: BlurtShared.Key.phase)
      KeyboardRig.listening(true)
      model.hasFullAccess = true
      model.appeared()
      #expect(model.termDraft == nil, "field open after an appearance (round \(round))")
      #expect(model.gate.isIdle, "gate latched after an appearance (round \(round))")
      #expect(model.isSettled, "in flight after an appearance (round \(round))")
      #expect(model.termSavedAt == nil, "saved check after an appearance (round \(round))")
      #expect(model.handshake.isIdle, "handshake not at rest after an appearance (round \(round))")
      // An error's line is the one thing kept, by design, until the tap that
      // clears it; that tap opens Blurt, and the ready record rests the handshake.
      if let line = model.statusLine, case .hop = line.tapOpens {
        model.tapMic()
        model.stateChanged()
      }
      #expect(model.statusLine == nil, "a line after an appearance (round \(round))")
      // And a tap is a press; answered, the next tap is its release.
      let before = commands.sent.count
      model.tapMic()
      #expect(
        commands.sent.count == before + 1 && commands.sent.last?.kind == .press, "tap is not a press (round \(round))")
      let dictation = UUID()
      rig.answer(.started(dictation))
      model.apply(snapshot(.recording, dictation: dictation))
      model.tapMic()
      #expect(commands.sent.last?.kind == .release, "second tap is not a release (round \(round))")
      #expect(commands.sent.last?.dictationID == dictation, "release for the wrong dictation (round \(round))")
      rig.answer(.stopped(dictation))
      model.apply(snapshot(.pasted, dictation: dictation))
      model.apply(snapshot(.idle))
    }
  }

  /// The app dies under whatever was going on: its lease lapses, the next
  /// read of the record refuses whatever the handshake held (a stop out runs
  /// to its own deadline first), the line says to tap, and the tap hops —
  /// with `suspended`, or with the held notice's own reason, since the words
  /// and the tap never disagree — and the gate comes up.
  private func appDies(
    _ rig: KeyboardRig, _ hops: KeyboardRig.Hops, controller: UIInputViewController?, round: Int,
    _ random: inout Random
  ) {
    let model = rig.model
    KeyboardRig.record(.open, micLive: true, age: ListeningState.lease + 1)
    model.stateChanged()
    if model.handshake.stopID != nil {
      drive(rig, .deadline, &random)
      model.stateChanged()
    }
    #expect(model.handshake.unreadyReason == .suspended, "a dead app not seen (round \(round))")
    #expect(model.gate.isIdle, "gate held over a dead app (round \(round))")
    let line = model.statusLine
    #expect(line != nil, "a dead app with no line (round \(round))")
    let expected: FailureReason? =
      if case .hop(let reason) = line?.tapOpens { reason ?? .suspended } else { .suspended }
    let hopsBefore = hops.opened.count
    model.controller = controller
    model.tapMic()
    model.controller = nil
    #expect(hops.opened.count == hopsBefore + 1, "the tap over a dead app did not hop (round \(round))")
    #expect(hops.opened.last == BlurtShared.startURL(reason: expected), "the hop's reason (round \(round))")
  }
}

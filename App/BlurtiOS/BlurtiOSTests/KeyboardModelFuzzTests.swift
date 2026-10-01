import Foundation
import Testing

@testable import BlurtiOS

/// The keyboard model driven through thousands of random event sequences —
/// every finger, phase, host and lifecycle event the real keyboard sees, in
/// any order — with the invariants that must hold after every one of them
/// checked each time. Seeded, so a failure names the sequence that made it.
/// This is the "nothing is ever left stale" check: a state the model can be
/// driven into and not out of shows up here as a broken invariant.
@Suite("Keyboard model: random transition sequences", .serialized)
@MainActor
struct KeyboardModelFuzzTests {
  /// One event the fuzz can send. `apply` phases come as the app would
  /// publish them; the rest are the keyboard's own entry points.
  enum Event: CaseIterable {
    case micDown, micUp, cancel
    case phaseIdle, phaseConnecting, phaseRecording, phaseProcessing, phasePasted, phaseCopied, phaseError
    case answerConnecting, answerError
    case appNotListening, appListening
    case beginTerm, cancelTerm, saveTerm, typeLetter, space, deleteBack, newline
    case selectWord, selectOther, clearSelection, addSelected, dismissSelected
    case flipPanel, toggleSymbols, toggleMore, toggleShift
    case appeared, disappeared, appearedNoAccess, contextChanged
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
  }

  final class Commands {
    var sent: [KeyboardCommand] = []
  }

  /// Set by an event after which the command ledger starts over.
  private final class Flag {
    var value = false
  }
  private let epochFlag = Flag()
  private var epoch: Bool {
    get { epochFlag.value }
    nonmutating set { epochFlag.value = newValue }
  }

  private func snapshot(_ state: PhaseSnapshot.State) -> PhaseSnapshot {
    PhaseSnapshot(state: state, message: nil, level: 0, at: Date())
  }

  private func listening(_ on: Bool) {
    let now = Date()
    SharedStore.listeningUntil = on ? now.addingTimeInterval(600) : nil
    SharedStore.appSeenAt = on ? now : nil
  }

  @Test(
    "ten thousand random events never leave the model in a stale or contradictory state", arguments: [1, 2, 3, 4, 5])
  func fuzz(seed: UInt64) {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    var random = Random(state: seed &* 7919)
    let proxy = FakeProxy()
    let model = KeyboardModel()
    model.proxyOverride = proxy
    model.hasFullAccess = true
    let commands = Commands()
    model.transport = { commands.sent.append($0) }
    listening(true)
    model.appeared()
    var trace: [Event] = []
    // The press the app has not taken yet: closed by our release or cancel,
    // by any in-flight phase (the app is on it), or by a settled phase that
    // names it. A second press while one is open is the protocol broken.
    var pressOpen: UUID?
    for step in 0..<2000 {
      let event = random.pick(Event.allCases)
      trace.append(event)
      let before = commands.sent.count
      drive(model, proxy, event, &random)
      if epoch {
        commands.sent.removeAll()
        pressOpen = nil
      }
      for command in commands.sent.dropFirst(min(before, commands.sent.count)) {
        switch command.kind {
        case .press:
          #expect(
            pressOpen == nil || pressOpen == command.id,
            "two presses in flight — seed \(seed) step \(step) after \(event); last 12: \(trace.suffix(12))")
          pressOpen = command.id
        case .release, .cancel: pressOpen = nil
        }
      }
      if Self.phaseEvents.contains(event), !model.isSettled || model.snapshot.command == pressOpen {
        pressOpen = nil
      }
      check(
        model, proxy, commands, after: event,
        "seed \(seed) step \(step) after \(event); last 12: \(trace.suffix(12))")
    }
  }

  // swiftlint:disable:next cyclomatic_complexity function_body_length
  private func drive(_ model: KeyboardModel, _ proxy: FakeProxy, _ event: Event, _ random: inout Random) {
    epoch = false
    switch event {
    case .micDown: model.micDown()
    case .micUp: model.micUp()
    case .cancel: model.cancel()
    case .phaseIdle: model.apply(snapshot(.idle))
    case .phaseConnecting: model.apply(snapshot(.connecting))
    case .phaseRecording: model.apply(snapshot(.recording))
    case .phaseProcessing: model.apply(snapshot(.processing))
    case .phasePasted: model.apply(snapshot(.pasted))
    case .phaseCopied: model.apply(snapshot(.copied))
    case .phaseError: model.apply(snapshot(.error))
    case .answerConnecting:
      model.apply(PhaseSnapshot(state: .connecting, message: nil, level: 0, at: Date(), command: model.unansweredPress))
    case .answerError:
      model.apply(PhaseSnapshot(state: .error, message: nil, level: 0, at: Date(), command: model.unansweredPress))
    case .appNotListening:
      listening(false)
      model.apply(model.snapshot)
    case .appListening:
      listening(true)
      model.apply(model.snapshot)
    case .beginTerm: model.beginAddingTerm()
    case .cancelTerm: model.cancelAddingTerm()
    case .saveTerm: model.saveTerm()
    case .typeLetter: model.type(random.pick(["a", "B", "z"]))
    case .space: model.space()
    case .deleteBack: model.deleteBackward()
    case .newline: model.newline()
    case .selectWord:
      proxy.selected = "Rizz"
      model.contextChanged()
    case .selectOther:
      proxy.selected = random.pick(["Gyatt", "neil bisht", " Rizz "])
      model.contextChanged()
    case .clearSelection:
      proxy.selected = nil
      model.contextChanged()
    case .addSelected: model.addSelectedTerm()
    case .dismissSelected: model.dismissSelection()
    case .flipPanel: model.flipPanel(towardsLeading: random.next() % 2 == 0)
    case .toggleSymbols: model.toggleSymbols()
    case .toggleMore: model.toggleMore()
    case .toggleShift: model.toggleShift()
    case .appeared:
      model.hasFullAccess = true
      model.appeared()
    case .appearedNoAccess:
      // Without Full Access the keyboard can't reach the app: whatever was
      // in flight is the app's to end; the command ledger starts over.
      model.hasFullAccess = false
      model.appeared()
      model.hasFullAccess = true
      epoch = true
    case .disappeared: model.disappeared()
    case .contextChanged: model.contextChanged()
    case .resultFresh:
      SharedStore.write(
        DictationResult(id: UUID(), text: "words", deliveredAt: Date(), recipient: nil), forKey: BlurtShared.Key.result)
      model.resultArrived()
    case .resultStale:
      SharedStore.write(
        DictationResult(id: UUID(), text: "old", deliveredAt: Date().addingTimeInterval(-60), recipient: nil),
        forKey: BlurtShared.Key.result)
      model.resultArrived()
    case .resultForOther:
      SharedStore.write(
        DictationResult(id: UUID(), text: "theirs", deliveredAt: Date(), recipient: "someone-else"),
        forKey: BlurtShared.Key.result)
      model.resultArrived()
    case .hostTyped:
      proxy.before += "x"
      model.contextChanged()
    case .hostMovedCursor:
      proxy.before += "ab"
      proxy.after = String(proxy.after.dropFirst(2))
      model.contextChanged()
    }
  }

  /// The events that apply a phase from the app.
  static let phaseEvents: Set<Event> = [
    .phaseIdle, .phaseConnecting, .phaseRecording, .phaseProcessing, .phasePasted, .phaseCopied, .phaseError,
    .answerConnecting, .answerError, .appNotListening, .appListening,
  ]

  /// The events after which the term field's shift has just been re-read.
  static let reevaluatesShift: Set<Event> = [
    .beginTerm, .cancelTerm, .saveTerm, .typeLetter, .space, .deleteBack, .newline, .contextChanged, .selectWord,
    .selectOther, .clearSelection, .hostTyped, .hostMovedCursor, .appeared, .appearedNoAccess,
  ]

  /// What must be true after every event, whatever came before.
  private func check(
    _ model: KeyboardModel, _ proxy: FakeProxy, _ commands: Commands, after event: Event, _ context: String
  ) {
    // The term field's bookkeeping lives and dies with the field.
    let fieldOpen = model.termDraft != nil
    #expect((model.termHostBaseline != nil) == fieldOpen, "term baseline vs field — \(context)")
    #expect((model.termHostBaselineAfter != nil) == fieldOpen, "term baseline-after vs field — \(context)")
    #expect(model.termDraftFromSelection == nil || fieldOpen, "seed outlives the field — \(context)")
    #expect(!fieldOpen || model.effectiveLayout == .full, "keys must be up for the field — \(context)")
    // Shift follows the term as typed; a tap on shift itself overrides it,
    // as on the system keyboard, until the next thing that re-reads it.
    if let draft = model.termDraft, Self.reevaluatesShift.contains(event) {
      #expect(model.shifted == (draft.isEmpty || draft.last == " "), "term shift rule — \(context)")
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
    // Pages.
    #expect(!model.morePage || model.symbolsPage, "#+= page without the symbols — \(context)")
    // The voice picture never shows what the app can't be doing.
    let state = model.voiceState
    if !state.isReady {
      #expect(
        !state.isRecording && state.glyph == nil && !state.canCancel, "in-flight picture with no app — \(context)")
    }
    // A latched gate is either a press of ours the app hasn't settled, or a
    // dictation in flight that the app published (started elsewhere, or a
    // phase that arrived after our cancel): never a latch over nothing.
    if !model.gate.isIdle {
      let inFlight = !model.isSettled
      #expect(commands.sent.last?.kind == .press || inFlight, "gate latched with no press out — \(context)")
    }
    #expect(!model.panelShowsKeys || model.layout == .panel, "keys page off the panel — \(context)")
    #expect(commands.sent.allSatisfy { $0.keyboard == model.instanceID }, "command from another keyboard — \(context)")
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
    let proxy = FakeProxy()
    let model = KeyboardModel()
    model.proxyOverride = proxy
    model.hasFullAccess = true
    let commands = Commands()
    model.transport = { commands.sent.append($0) }
    listening(true)
    // Hands-free off: a tap must be the press here, not the stop of one the
    // appearance started.
    SharedStore.autoDictate = false
    model.appeared()
    for round in 0..<200 {
      for _ in 0..<25 { drive(model, proxy, random.pick(Event.allCases), &random) }
      // The keyboard goes away and comes back, the app idle and listening.
      model.disappeared()
      SharedStore.write(snapshot(.idle), forKey: BlurtShared.Key.phase)
      listening(true)
      model.hasFullAccess = true
      model.appeared()
      #expect(model.termDraft == nil, "field open after an appearance (round \(round))")
      #expect(!model.panelShowsKeys, "keys page after an appearance (round \(round))")
      #expect(model.gate.isIdle, "gate latched after an appearance (round \(round))")
      #expect(model.isSettled, "in flight after an appearance (round \(round))")
      #expect(model.termSavedAt == nil, "saved check after an appearance (round \(round))")
      // And a tap is a press.
      let before = commands.sent.count
      model.micDown()
      model.micUp()
      #expect(
        commands.sent.count == before + 1 && commands.sent.last?.kind == .press, "tap is not a press (round \(round))")
      model.apply(snapshot(.recording))
      model.micDown()
      model.micUp()
      #expect(commands.sent.last?.kind == .release, "second tap is not a release (round \(round))")
      model.apply(snapshot(.pasted))
      model.apply(snapshot(.idle))
    }
  }
}

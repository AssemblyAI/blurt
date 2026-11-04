import Foundation
import Synchronization
import Testing

@testable import BlurtEngine

/// The router carrying out a Control Your Mac press end to end: the spoken
/// command recorded by the session, the plan, each step performed, and a typed
/// step pasted through the session's own injector.
@MainActor
@Suite("SelectionSpeechRouter · Command")
struct VoiceCommandRouterTests {
  private let defaults = freshDefaults()

  /// Runs one held command press of right ⌥, the session transcribing the
  /// command as "Open Slack and search for budget.", up to the planner's call.
  private func command(
    _ planner: StubPlanner, performer: StubPerformer = StubPerformer(),
    injectorError: (any Error & Sendable)? = nil
  ) async throws -> Rig {
    let rig = try await press(
      saying: "Open Slack and search for budget.", planner, performer: performer, injectorError: injectorError)
    try await waitUntil { !planner.calls.isEmpty }
    return rig
  }

  /// One held command press of right ⌥ transcribed as `said`, returned as
  /// soon as the key is up.
  private func press(
    saying said: String, _ planner: StubPlanner, performer: StubPerformer = StubPerformer(),
    injectorError: (any Error & Sendable)? = nil
  ) async throws -> Rig {
    let fixture = makeSession(mode: .transcript(said))
    await fixture.injector.setError(injectorError)
    let router = SelectionSpeechRouter(
      session: fixture.session, speaker: GatedSpeaker(), planner: planner, performer: performer,
      readSelection: { nil }, defaults: defaults)
    TriggerKeyStyleStore(defaults: defaults).setChoice(.command, for: .rightOption)
    let events = JobEvents(watching: router)
    let phases = try await speakHeldPress(router, on: fixture)
    return Rig(router: router, events: events, injector: fixture.injector, performer: performer, phases: phases)
  }

  @MainActor
  private struct Rig {
    let router: SelectionSpeechRouter
    let events: JobEvents
    let injector: StubInjector
    let performer: StubPerformer
    let phases: Task<Void, Never>

    /// What the pill showed after "Working", once the command has ended.
    func outcomes() async throws -> [OverlayUIState?] {
      try await events.outcomes(after: .commanding, stopping: phases)
    }
  }

  private static let slackSearch: [VoiceCommandStep] = [
    .openApp("Slack"), .shortcut(KeyChord(modifiers: .command, key: .character("k"))), .type("budget"),
  ]

  @Test("the spoken command is planned with what's on screen, then each step runs in order and the pill says Done")
  func runsSteps() async throws {
    let planner = StubPlanner(steps: Self.slackSearch)
    let screen = ScreenContext(
      appName: "Safari", windowTitle: "Start Page", elements: [.init(id: 1, kind: "button", label: "Back")])
    let rig = try await command(planner, performer: StubPerformer(screen: screen))
    #expect(try await rig.outcomes() == [.done])
    #expect(planner.calls == [StubPlanner.Call(command: "Open Slack and search for budget.", context: screen)])
    // Read once, at the release, while the command transcribed: not again to plan.
    #expect(rig.performer.screenReads == 1)
    #expect(rig.performer.performed == Array(Self.slackSearch.prefix(2)))
    // Typed where focus is now — in Slack — not back in the app the press
    // captured, and without touching the target the next press will pin.
    #expect(await rig.injector.insertedAtFocus == ["budget"])
    #expect(await rig.injector.inserted.isEmpty)
    // One pin, the press's own: the typed step set none.
    #expect(await rig.injector.targets.count == 1)
  }

  @Test("a typed step with nothing editable focused ends the command there, as a quiet Copied")
  func typedToClipboardStops() async throws {
    let planner = StubPlanner(steps: [.type("budget"), .shortcut(KeyChord(modifiers: [], key: .code(0x24)))])
    let rig = try await command(planner, injectorError: BlurtError.noEditableTarget)
    #expect(try await rig.outcomes() == [.noTarget])
    #expect(rig.performer.performed.isEmpty)
  }

  @Test("a step that fails ends the command and names the app on the pill")
  func failedStepNamesApp() async throws {
    let planner = StubPlanner(steps: [
      .openApp("Figma"), .shortcut(KeyChord(modifiers: .command, key: .character("n"))),
    ])
    let rig = try await command(planner, performer: StubPerformer(error: VoiceCommandError.appNotFound("Figma")))
    #expect(
      try await rig.outcomes() == [
        .error(
          message: "No app named Figma is installed.",
          notice: PillNotice(subject: "Figma", predicate: "isn’t installed"))
      ])
    #expect(rig.performer.performed.isEmpty)
  }

  @Test("the performer hears of the command when its press proves itself, and again when it's over")
  func lifecycle() async throws {
    let performer = StubPerformer()
    let rig = try await command(StubPlanner(steps: [.media(.mute)]), performer: performer)
    #expect(try await rig.outcomes() == [.done])
    try await waitUntil { performer.events.count == 2 }
    #expect(performer.events == ["starting", "ended"])
  }

  @Test("an abandoned command still tells the performer it's over")
  func abandonedLifecycle() async throws {
    let performer = StubPerformer()
    let rig = try await command(StubPlanner(steps: [.media(.mute)], hangs: true), performer: performer)
    rig.router.press(key: .rightCommand)
    try await waitUntil { performer.events.count == 2 }
    rig.phases.cancel()
    #expect(performer.events == ["starting", "ended"])
  }

  @Test("a failure's public log kind names the error's case, never what it carries")
  func logKind() {
    #expect(
      SelectionSpeechRouter.logName(of: VoiceCommandError.unsafeURL("https://evil.example/?q=secret"))
        == "VoiceCommandError.unsafeURL")
    #expect(SelectionSpeechRouter.logName(of: VoiceCommandError.notUnderstood) == "VoiceCommandError.notUnderstood")
  }

  @Test("a complaint about the last command is noted, not planned")
  func complaintIsNoted() async throws {
    let planner = StubPlanner(steps: [.media(.mute)])
    let rig = try await press(saying: "That last command didn't work.", planner)
    try await waitUntil { rig.events.pills.contains(.noted) }
    rig.phases.cancel()
    #expect(planner.calls.isEmpty)
    #expect(!rig.router.ownsPill)
  }

  @Test("each step is recorded as it runs: how it ran, and the error that stopped the rest")
  func stepRecords() async throws {
    let fixture = makeSession(mode: .transcript("x"))
    let ran = SelectionSpeechRouter.StepLog()
    let screen = ScreenContext(appName: "Mail", elements: [.init(id: 4, kind: "button", label: "Reply")])
    _ = try await SelectionSpeechRouter.perform(
      [.pressElement(4), .type("hi")], in: screen, performer: StubPerformer(), session: fixture.session, recording: ran)
    #expect(ran.records.map(\.step) == ["press #4 (button \"Reply\")", "type \"hi\""])
    #expect(ran.records.map(\.how) == ["stubbed", "pasted"])
    #expect(ran.records.allSatisfy { $0.error == nil })

    let failed = SelectionSpeechRouter.StepLog()
    await #expect(throws: VoiceCommandError.self) {
      try await SelectionSpeechRouter.perform(
        [.openApp("Figma"), .media(.mute)], in: screen,
        performer: StubPerformer(error: VoiceCommandError.appNotFound("Figma")), session: fixture.session,
        recording: failed)
    }
    #expect(failed.records.map(\.step) == ["open_app Figma"])
    #expect(failed.records.first?.error == "No app named Figma is installed.")

    // Failing partway: the steps before it ran and are recorded as they ran,
    // the one that failed carries its error, and the rest never start.
    let partway = SelectionSpeechRouter.StepLog()
    let performer = StubPerformer(error: VoiceCommandError.elementGone, failingAt: 1)
    await #expect(throws: VoiceCommandError.elementGone) {
      try await SelectionSpeechRouter.perform(
        [.media(.mute), .pressElement(4), .media(.playPause)], in: screen, performer: performer,
        session: fixture.session, recording: partway)
    }
    #expect(performer.performed == [.media(.mute)])
    #expect(partway.records.map(\.step) == ["media mute", "press #4 (button \"Reply\")"])
    #expect(partway.records.map(\.error) == [nil, "That control isn’t there any more."])
  }

  @Test("a missing key is a setup state, as it is for a dictation: the pill goes calm, not red")
  func missingKeyIsCalm() async throws {
    let rig = try await command(StubPlanner(error: BlurtError.apiKeyMissing))
    #expect(try await rig.outcomes() == [.idle])
  }

  @Test("a cancelled-looking error on a command nobody cancelled fails it, rather than leaving the pill on Working")
  func strayCancellation() async throws {
    let rig = try await command(StubPlanner(error: URLError(.cancelled)))
    let outcomes = try await rig.outcomes()
    #expect(outcomes.count == 1)
    guard case .error = outcomes.first else {
      Issue.record("expected a failure, got \(outcomes)")
      return
    }
    #expect(!rig.router.ownsPill)
    #expect(rig.performer.events.last == "ended")
  }

  @Test("a press while the command is planning abandons it: nothing run, one end, no late one")
  func pressAbandons() async throws {
    let rig = try await command(StubPlanner(steps: Self.slackSearch, hangs: true))
    let resetsBefore = rig.events.resets
    rig.router.press(key: .rightCommand)
    #expect(rig.events.pills == [.commanding, nil])
    #expect(!rig.router.ownsPill)
    try await Task.sleep(for: .milliseconds(100))
    rig.phases.cancel()
    #expect(rig.events.pills == [.commanding, nil])
    #expect(rig.events.resets == resetsBefore)
    #expect(rig.performer.performed.isEmpty)
    #expect(await rig.injector.inserted.isEmpty)
  }
}

/// A planner that records each call and answers with `steps`, or throws
/// `error` — or, `hangs`, plans until cancelled.
final class StubPlanner: VoiceCommandPlanning {
  struct Call: Equatable {
    let command: String
    let context: ScreenContext
  }

  private let steps: [VoiceCommandStep]
  private let error: (any Error & Sendable)?
  private let hangs: Bool
  private let recorded = Mutex<[Call]>([])

  init(steps: [VoiceCommandStep] = [], error: (any Error & Sendable)? = nil, hangs: Bool = false) {
    self.steps = steps
    self.error = error
    self.hangs = hangs
  }

  var calls: [Call] { recorded.withLock { $0 } }

  func plan(_ command: String, context: ScreenContext, trace: PlanTrace) async throws -> [VoiceCommandStep] {
    recorded.withLock { $0.append(Call(command: command, context: context)) }
    if hangs { try await Task.sleep(for: .seconds(60)) }
    if let error { throw error }
    return steps
  }
}

/// A performer that records each step it carried out, or throws `error` on the first.
final class StubPerformer: VoiceCommandPerforming {
  private let screen: ScreenContext
  private let error: (any Error & Sendable)?
  /// Which step `error` is thrown at, by index; every step when nil.
  private let failingAt: Int?
  private let recorded = Mutex<[VoiceCommandStep]>([])
  private let lifecycle = Mutex<[String]>([])
  private let reads = Mutex(0)

  init(
    screen: ScreenContext = ScreenContext(appName: nil), error: (any Error & Sendable)? = nil, failingAt: Int? = nil
  ) {
    self.screen = screen
    self.error = error
    self.failingAt = failingAt
  }

  var performed: [VoiceCommandStep] { recorded.withLock { $0 } }
  /// "starting" and "ended", in the order the router called them.
  var events: [String] { lifecycle.withLock { $0 } }

  func commandStarting() async { lifecycle.withLock { $0.append("starting") } }
  func commandEnded() async { lifecycle.withLock { $0.append("ended") } }

  /// How many times the screen was read.
  var screenReads: Int { reads.withLock { $0 } }

  func screenContext() async -> ScreenContext {
    reads.withLock { $0 += 1 }
    return screen
  }

  func perform(_ step: VoiceCommandStep) async throws -> String? {
    if let error, failingAt == nil || failingAt == performed.count { throw error }
    recorded.withLock { $0.append(step) }
    return "stubbed"
  }
}

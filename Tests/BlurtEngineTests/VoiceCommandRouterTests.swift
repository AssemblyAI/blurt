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
    let fixture = makeSession(mode: .transcript("Open Slack and search for budget."))
    await fixture.injector.setError(injectorError)
    let router = SelectionSpeechRouter(
      session: fixture.session, speaker: GatedSpeaker(), planner: planner, performer: performer,
      readSelection: { nil }, defaults: defaults)
    TriggerKeyStyleStore(defaults: defaults).setChoice(.command, for: .rightOption)
    let events = CommandEvents()
    router.commandPill = { events.pills.append($0) }
    router.resetGate = { events.resets += 1 }
    let phases = try await speakHeldPress(router, on: fixture)
    try await waitUntil { !planner.calls.isEmpty }
    return Rig(router: router, events: events, injector: fixture.injector, performer: performer, phases: phases)
  }

  @MainActor
  private struct Rig {
    let router: SelectionSpeechRouter
    let events: CommandEvents
    let injector: StubInjector
    let performer: StubPerformer
    let phases: Task<Void, Never>

    /// What the pill showed after "Working", once the command has ended.
    func outcomes() async throws -> [OverlayUIState?] {
      defer { phases.cancel() }
      try await waitUntil { events.pills.count > 1 }
      #expect(events.pills.first == .commanding)
      return Array(events.pills.dropFirst())
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
    #expect(rig.performer.performed == Array(Self.slackSearch.prefix(2)))
    // Typed where focus is now — in Slack — not back in the app the press captured.
    #expect(await rig.injector.inserted == ["budget"])
    #expect(await rig.injector.targets.last == .some(nil))
    #expect(await rig.injector.insertedPrior == [nil])
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

  @Test("a missing key is a setup state, as it is for a dictation: the pill goes calm, not red")
  func missingKeyIsCalm() async throws {
    let rig = try await command(StubPlanner(error: BlurtError.apiKeyMissing))
    #expect(try await rig.outcomes() == [.idle])
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

/// What a command press reported.
@MainActor
private final class CommandEvents {
  var pills: [OverlayUIState?] = []
  var resets = 0
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

  func plan(_ command: String, context: ScreenContext) async throws -> [VoiceCommandStep] {
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
  private let recorded = Mutex<[VoiceCommandStep]>([])
  private let lifecycle = Mutex<[String]>([])

  init(screen: ScreenContext = ScreenContext(appName: nil), error: (any Error & Sendable)? = nil) {
    self.screen = screen
    self.error = error
  }

  var performed: [VoiceCommandStep] { recorded.withLock { $0 } }
  /// "starting" and "ended", in the order the router called them.
  var events: [String] { lifecycle.withLock { $0 } }

  func commandStarting() async { lifecycle.withLock { $0.append("starting") } }
  func commandEnded() async { lifecycle.withLock { $0.append("ended") } }

  func screenContext() async -> ScreenContext { screen }

  func perform(_ step: VoiceCommandStep) async throws {
    if let error { throw error }
    recorded.withLock { $0.append(step) }
  }
}

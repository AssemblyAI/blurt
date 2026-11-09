import Foundation
import Testing

@testable import BlurtEngine

/// The router carrying out a Compose From Instructions press end to end: the
/// spoken instructions recorded by the session, the composition for the app
/// in front, and the paste through the session's own injector.
@MainActor
@Suite("SelectionSpeechRouter · Compose")
struct SelectionSpeechRouterComposeTests {
  private let defaults = freshDefaults()

  /// Runs one held compose press of right ⌥, the session transcribing the
  /// instructions as "Tell Dan we should ship it.", the press pinning Slack.
  private func compose(
    _ composer: StubComposer, injectorError: (any Error & Sendable)? = nil
  ) async throws -> Rig {
    let fixture = makeSession(
      mode: .transcript("Tell Dan we should ship it."), frontmost: CapturedFocus(pid: 42, processName: "Slack"))
    await fixture.injector.setError(injectorError)
    let router = SelectionSpeechRouter(
      session: fixture.session, speaker: GatedSpeaker(), composer: composer,
      // A compose press never reads the selection: this would fail it if it did.
      readSelection: {
        Issue.record("a compose press read the selection")
        return nil
      }, defaults: defaults)
    TriggerKeyStyleStore(defaults: defaults).setChoice(.compose, for: .rightOption)
    let events = JobEvents(watching: router)
    let phases = try await speakHeldPress(router, on: fixture)
    try await waitUntil { !composer.calls.isEmpty }
    return Rig(router: router, events: events, injector: fixture.injector, phases: phases)
  }

  /// A compose press's router, what it reported, and the injector it pasted through.
  @MainActor
  private struct Rig {
    let router: SelectionSpeechRouter
    let events: JobEvents
    let injector: StubInjector
    let phases: Task<Void, Never>

    /// What the pill showed after "Writing", once the composition has ended.
    func outcomes() async throws -> [OverlayUIState?] {
      try await events.outcomes(after: .composing, stopping: phases)
    }
  }

  @Test("the spoken instructions are written for the app the press pinned and pasted there with no separator")
  func pastesComposition() async throws {
    let composer = StubComposer(reply: "Hey Dan, let's ship it.")
    let rig = try await compose(composer)
    let injector = rig.injector
    #expect(try await rig.outcomes() == [.pasted])
    #expect(composer.calls == [ComposeCall(instructions: "Tell Dan we should ship it.", app: "Slack")])
    #expect(await injector.inserted == ["Hey Dan, let's ship it."])
    #expect(await injector.insertedPrior == [nil])
    #expect(await injector.insertedWindowTitles == [nil])
  }

  @Test("with nothing editable focused, the composition is a quiet Copied")
  func noTargetIsQuiet() async throws {
    let rig = try await compose(StubComposer(reply: "Hey Dan"), injectorError: BlurtError.noEditableTarget)
    #expect(try await rig.outcomes() == [.noTarget])
  }

  @Test("a failed composition pastes nothing and shows the error")
  func failureShowsError() async throws {
    let rig = try await compose(StubComposer(error: ReadAloudLLMError.truncated))
    #expect(try await rig.outcomes() == [.error(message: "The LLM Gateway's rewrite was cut short.")])
    #expect(await rig.injector.inserted.isEmpty)
  }

  @Test("a press while the model is still writing abandons it: nothing pasted, one end, no late one")
  func pressAbandons() async throws {
    let rig = try await compose(StubComposer(hangs: true))
    rig.router.press(key: .rightCommand)
    #expect(rig.events.pills == [.composing, nil])
    try await Task.sleep(for: .milliseconds(100))
    rig.phases.cancel()
    #expect(rig.events.pills == [.composing, nil])
    #expect(await rig.injector.inserted.isEmpty)
  }
}

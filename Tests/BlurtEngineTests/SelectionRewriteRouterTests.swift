import Foundation
import Synchronization
import Testing

@testable import BlurtEngine

/// The router carrying out a Rewrite Selection press end to end: the spoken
/// instruction recorded by the session, the rewrite, and the paste through the
/// session's own injector.
@MainActor
@Suite("SelectionSpeechRouter · Rewrite")
struct SelectionRewriteRouterTests {
  private let defaults = freshDefaults()

  /// Runs one held rewrite press of right ⌥ over "hey all", the session
  /// transcribing the instruction as "Make it more formal.", up to the
  /// rewriter's call. The rig's events record what the pill was told.
  private func rewrite(
    _ rewriter: StubRewriter, injectorError: (any Error & Sendable)? = nil
  ) async throws -> Rig {
    let fixture = makeSession(mode: .transcript("Make it more formal."))
    await fixture.injector.setError(injectorError)
    let router = SelectionSpeechRouter(
      session: fixture.session, speaker: GatedSpeaker(), rewriter: rewriter, readSelection: { "hey all" },
      defaults: defaults)
    TriggerKeyStyleStore(defaults: defaults).setChoice(.rewrite, for: .rightOption)
    let events = RewriteEvents()
    router.rewritePill = { events.pills.append($0) }
    router.resetGate = { events.resets += 1 }
    let phases = try await speakHeldPress(router, on: fixture)
    try await waitUntil { !rewriter.calls.isEmpty }
    return Rig(router: router, events: events, injector: fixture.injector, phases: phases)
  }

  /// A rewrite press's router, what it reported, and the injector it pasted through.
  @MainActor
  private struct Rig {
    let router: SelectionSpeechRouter
    let events: RewriteEvents
    let injector: StubInjector
    let phases: Task<Void, Never>

    /// What the pill showed after "Rewriting", once the rewrite has ended.
    func outcomes() async throws -> [OverlayUIState?] {
      defer { phases.cancel() }
      try await waitUntil { events.pills.count > 1 }
      #expect(events.pills.first == .rewriting)
      return Array(events.pills.dropFirst())
    }
  }

  @Test("the spoken instruction rewrites the selection, pasted over it with no separator")
  func pastesRewrite() async throws {
    let rewriter = StubRewriter(reply: "Dear all,")
    let rig = try await rewrite(rewriter)
    let injector = rig.injector
    #expect(try await rig.outcomes() == [.pasted])
    #expect(rewriter.calls == [StubRewriter.Call(selection: "hey all", request: "Make it more formal.")])
    #expect(await injector.inserted == ["Dear all,"])
    // Nothing for the separator to go on: the paste replaces, never follows.
    #expect(await injector.insertedPrior == [nil])
    #expect(await injector.insertedWindowTitles == [nil])
  }

  @Test("with nothing editable focused, the rewrite is a quiet Copied, as a dictation's would be")
  func noTargetIsQuiet() async throws {
    let rig = try await rewrite(StubRewriter(reply: "Dear all,"), injectorError: BlurtError.noEditableTarget)
    #expect(try await rig.outcomes() == [.noTarget])
  }

  @Test("a failed rewrite pastes nothing and shows the error")
  func failureShowsError() async throws {
    let rig = try await rewrite(StubRewriter(error: ReadAloudLLMError.truncated))
    #expect(try await rig.outcomes() == [.error(message: "The LLM Gateway's rewrite was cut short.")])
    #expect(await rig.injector.inserted.isEmpty)
  }

  @Test("a missing key is a setup state, as it is for a dictation: the pill goes calm, not red")
  func missingKeyIsCalm() async throws {
    let rig = try await rewrite(StubRewriter(error: BlurtError.apiKeyMissing))
    #expect(try await rig.outcomes() == [.idle])
  }

  @Test("a press while the model is still writing abandons the rewrite: nothing pasted, one end, no late one")
  func pressAbandons() async throws {
    let rig = try await rewrite(StubRewriter(hangs: true))
    let resetsBefore = rig.events.resets
    // The dictation key: it dictates, and the rewrite is gone at once.
    rig.router.press(key: .rightCommand)
    #expect(rig.events.pills == [.rewriting, nil])
    try await Task.sleep(for: .milliseconds(100))
    rig.phases.cancel()
    #expect(rig.events.pills == [.rewriting, nil])
    #expect(rig.events.resets == resetsBefore)
    #expect(await rig.injector.inserted.isEmpty)
  }
}

/// What a rewrite press reported.
@MainActor
private final class RewriteEvents {
  var pills: [OverlayUIState?] = []
  var resets = 0
}

/// A rewriter that records each call and answers with `reply`, or throws
/// `error` — or, `hangs`, writes until cancelled.
final class StubRewriter: SelectionRewriting {
  struct Call: Equatable {
    let selection: String
    let request: String
  }

  private let reply: String
  private let error: (any Error & Sendable)?
  private let hangs: Bool
  private let recorded = Mutex<[Call]>([])

  init(reply: String = "", error: (any Error & Sendable)? = nil, hangs: Bool = false) {
    self.reply = reply
    self.error = error
    self.hangs = hangs
  }

  var calls: [Call] { recorded.withLock { $0 } }

  func rewrite(_ selection: String, as request: String) async throws -> String {
    recorded.withLock { $0.append(Call(selection: selection, request: request)) }
    if hangs { try await Task.sleep(for: .seconds(60)) }
    if let error { throw error }
    return reply
  }
}

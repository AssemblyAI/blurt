import Foundation
import Testing

@testable import BlurtEngine

/// A hand-back press (`press(handingBack: true)`, read-aloud's "ask about the
/// selection") is a full dictation whose transcript ends the run as
/// `.handedBack` instead of being pasted.
@Suite("DictationSession hand-back")
struct DictationSessionHandBackTests {
  @Test("the transcript comes back as .handedBack and nothing is pasted")
  func handsBack() async {
    let fixture = makeSession(mode: .transcript("Give me a high-level summary."))
    await fixture.session.press(handingBack: true)
    await fixture.session.release()
    await fixture.session.waitForIdle()

    #expect(await fixture.session.phase == .handedBack("Give me a high-level summary."))
    #expect(await fixture.injector.inserted.isEmpty)
  }

  @Test("a request is never remembered as a dictation, nor reported as one")
  func notRemembered() async {
    let delivered = Counter()
    let fixture = makeSession(
      mode: .transcript("What does this mean?"),
      onTranscriptDelivered: { _, _ in _ = delivered.next() })
    await fixture.session.press(handingBack: true)
    await fixture.session.release()
    await fixture.session.waitForIdle()

    #expect(await fixture.session.recentDictations.spokenOldestFirst.isEmpty)
    #expect(delivered.value == 0)
  }

  @Test("the spoken words come back as said, without text shortcuts expanded")
  func noShortcutExpansion() async {
    let fixture = makeSession(
      mode: .transcript("Email it to my personal email"),
      textShortcuts: [TextShortcut(trigger: "personal email", expansion: "me@example.com")])
    await fixture.session.press(handingBack: true)
    await fixture.session.release()
    await fixture.session.waitForIdle()

    #expect(await fixture.session.phase == .handedBack("Email it to my personal email"))
  }

  @Test("nothing said ends in .idle, as a dictation's empty transcript does")
  func nothingSaid() async {
    let fixture = makeSession(mode: .transcript("   "))
    await fixture.session.press(handingBack: true)
    await fixture.session.release()
    await fixture.session.waitForIdle()

    #expect(await fixture.session.phase == .idle)
  }

  @Test("the next ordinary press pastes again")
  func flagIsPerPress() async {
    let fixture = makeSession(mode: .transcript("Hello world."))
    await fixture.session.press(handingBack: true)
    await fixture.session.release()
    await fixture.session.waitForIdle()
    await fixture.session.press()
    await fixture.session.release()
    await fixture.session.waitForIdle()

    #expect(await fixture.session.phase == .pasted)
    #expect(await fixture.injector.inserted == ["Hello world."])
  }

  @Test("submit(.pressHandingBack) is the same press through the command feed")
  func submitted() async {
    let fixture = makeSession(mode: .transcript("Summarize this."))
    // Subscribed before submitting, so the stream can't miss the phase.
    let phases = await fixture.session.phaseStream()
    let ended = Task { () -> PipelinePhase? in
      for await phase in phases {
        if case .handedBack = phase { return phase }
      }
      return nil
    }
    fixture.session.submit(.pressHandingBack)
    while await fixture.session.phase != .recording { await Task.yield() }
    fixture.session.submit(.release)

    #expect(await ended.value == .handedBack("Summarize this."))
  }

  @Test("a hand-back phase is terminal, hides the pill and reads as idle on the menu bar")
  func projections() {
    let phase = PipelinePhase.handedBack("x")
    #expect(phase.isTerminal)
    #expect(!phase.isCapturing)
    #expect(phase.overlayState == .idle)
    #expect(phase.menuBarStatus == .idle)
    #expect(phase.setupBlocker == nil)
  }
}

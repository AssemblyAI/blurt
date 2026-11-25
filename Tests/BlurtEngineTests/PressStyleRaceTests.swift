import Foundation
import Testing

@testable import BlurtEngine

/// A press refused while the last dictation transcribes must not restyle it:
/// the style is resolved on the press's own turn, past the session's guard.
@Suite("Press style across a refused press", .timeLimit(.minutes(1)))
struct PressStyleRaceTests {
  @Test("the Recent row names the style its own press resolved, not a refused later one's")
  func refusedPressKeepsTheStyle() async {
    let casual = PressStyle(instructions: "keep it breezy", name: "Casual")
    let formal = PressStyle(instructions: "no contractions", name: "Formal")
    let transcriber = GatedTranscriber(text: "Hello world.")
    let styleForKey: @Sendable (TriggerKey?) -> PressStyle = { $0 == .rightOption ? casual : formal }
    let session = makeSession(transcriber: transcriber, pressStyle: styleForKey)

    await session.press(key: .rightOption)
    await session.release()
    await transcriber.waitUntilStarted()
    // Refused: the dictation above is still transcribing.
    await session.press(key: .function)
    await transcriber.allowToFinish()
    await session.waitForIdle()

    #expect(await session.recentDictations.entries.map(\.style) == ["Casual"])
  }
}

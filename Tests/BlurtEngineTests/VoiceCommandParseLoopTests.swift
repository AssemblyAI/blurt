import Testing

@testable import BlurtEngine

/// Which step a looping plan is refused under, when more than one loops.
@Suite("VoiceCommandStep · Parse · loops")
struct VoiceCommandParseLoopTests {
  @Test("of two steps each back three times, the refusal names the first to loop")
  func cyclingNamesTheFirst() {
    let find = #"{"action": "shortcut", "keys": "cmd+f"}"#
    let down = #"{"action": "scroll", "direction": "down"}"#
    let reply = #"{"steps": ["# + Array(repeating: find + ", " + down, count: 3).joined(separator: ", ") + "]}"
    #expect(throws: VoiceCommandError.repeatedStep("shortcut")) {
      try VoiceCommandStep.steps(fromReply: reply, maxSteps: 10)
    }
  }
}

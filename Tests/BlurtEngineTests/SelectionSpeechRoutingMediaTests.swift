import Testing

@testable import BlurtEngine

@Suite("SelectionSpeechRouting · Music pause inputs")
struct SelectionSpeechRoutingMediaTests {
  @Test("a press is under way from its key-down until the router is back at rest")
  func handlingPress() {
    var routing = SelectionSpeechRouting()
    #expect(!routing.isHandlingPress)
    _ = routing.press(key: .rightOption, action: .command, holds: true)
    #expect(routing.isHandlingPress)
    _ = routing.submit(.cancel)
    #expect(!routing.isHandlingPress)
  }

  @Test("only a command's recording counts as a command's")
  func recordsCommand() {
    var command = SelectionSpeechRouting()
    _ = command.press(key: .rightOption, action: .command, holds: true)
    #expect(!command.recordsCommand)
    _ = command.holdElapsed()
    #expect(command.recordsCommand)

    var ask = SelectionSpeechRouting()
    _ = ask.press(key: .rightOption, action: .ask, holds: true)
    _ = ask.selectionResolved("hey all")
    _ = ask.holdElapsed()
    #expect(ask.isHandlingPress && !ask.recordsCommand)
  }
}

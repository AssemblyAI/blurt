import Foundation
import Testing

@testable import AssemblyAI
@testable import BlurtEngine

@Suite("VoiceCommandPlanner")
struct VoiceCommandPlannerTests {
  private func planner(_ transport: any HTTPTransport) -> VoiceCommandPlanner {
    VoiceCommandPlanner(apiKeyProvider: { "raw-key" }, transport: transport)
  }

  @Test("posts one chat completion to Gemma: the instruction as system, the app in front and the command as user")
  func request() async throws {
    let sent = ValueBox<URLRequest?>(nil)
    let transport = FakeHTTPTransport { request in
      sent.value = request
      return (200, completion(#"{"steps": [{"action": "shortcut", "keys": "cmd+t"}]}"#))
    }
    let screen = ScreenContext(appName: "Safari")
    let steps = try await planner(transport).plan("new tab", context: screen)
    #expect(steps == [.shortcut(KeyChord(modifiers: .command, key: .character("t")))])

    let request = try #require(sent.value)
    #expect(request.url == ReadAloudLLM.endpoint)
    #expect(request.timeoutInterval == VoiceCommandPlanner.timeout)
    let body = try #require(request.httpBody)
    let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(object["model"] as? String == "gemma-4-31b")
    #expect(object["max_tokens"] as? Int == VoiceCommandPlanner.maxTokens)
    let messages = try #require(object["messages"] as? [[String: String]])
    #expect(
      messages == [
        ["role": "system", "content": VoiceCommandPlanner.instruction],
        [
          "role": "user",
          "content": "<frontmost_app>\nSafari\n</frontmost_app>\n\n<spoken_command>\nnew tab\n</spoken_command>",
        ],
      ])
    // The plan's shape rides as a strict JSON schema the gateway enforces.
    let format = try #require(object["response_format"] as? [String: Any])
    #expect(format["type"] as? String == "json_schema")
    let schema = try #require(format["json_schema"] as? [String: Any])
    #expect(schema["strict"] as? Bool == true)
    #expect(schema["name"] as? String == "plan")
  }

  @Test("a plan that can't be used is asked for once more, with the model's reply and what was wrong")
  func retriesOnce() async throws {
    let sent = ValueBox<[URLRequest]>([])
    let replies = ValueBox([
      #"{"steps": [{"action": "press", "element": 9}]}"#, #"{"steps": [{"action": "press", "element": 1}]}"#,
    ])
    let transport = FakeHTTPTransport { request in
      sent.value.append(request)
      return (200, completion(replies.value.removeFirst()))
    }
    let screen = ScreenContext(appName: "Mail", elements: [.init(id: 1, kind: "button", label: "Reply")])
    #expect(try await planner(transport).plan("reply", context: screen) == [.pressElement(1)])
    #expect(sent.value.count == 2)
    let retry = try #require(sent.value.last?.httpBody)
    let object = try #require(try JSONSerialization.jsonObject(with: retry) as? [String: Any])
    let messages = try #require(object["messages"] as? [[String: String]])
    #expect(messages.map { $0["role"] } == ["system", "user", "assistant", "user"])
    #expect(messages[2]["content"] == #"{"steps": [{"action": "press", "element": 9}]}"#)
    #expect(messages[3]["content"]?.contains("element 9, which isn’t on screen") == true)
  }

  @Test("an empty plan is the model's own answer, never asked again")
  func emptyPlanNotRetried() async {
    let calls = Counter()
    let transport = FakeHTTPTransport { _ in
      _ = calls.next()
      return (200, completion(#"{"steps": []}"#))
    }
    await #expect(throws: VoiceCommandError.notUnderstood) {
      try await planner(transport).plan("empty the trash", context: ScreenContext(appName: "Finder"))
    }
    #expect(calls.value == 1)
  }

  @Test("with no app in front, only the command is sent")
  func noFrontmostApp() {
    #expect(
      VoiceCommandPlanner.prompt("mute", context: ScreenContext(appName: nil))
        == "<spoken_command>\nmute\n</spoken_command>")
  }

  @Test("the window's elements go before the command, numbered, and a plan may name only those numbers")
  func windowElements() async throws {
    let screen = ScreenContext(
      appName: "Mail", windowTitle: "Inbox",
      elements: [.init(id: 1, kind: "button", label: "Reply"), .init(id: 2, kind: "search field", label: "Search")])
    #expect(
      VoiceCommandPlanner.prompt("reply", context: screen, fence: "c0de")
        == "<frontmost_app>\nMail\n</frontmost_app>\n\n<window fence=\"c0de\" title=\"Inbox\">\n"
        + "[1] button \"Reply\"\n[2] search field \"Search\"\n</window fence=\"c0de\">\n\n"
        + "<spoken_command>\nreply\n</spoken_command>")

    let pressesOne = FakeHTTPTransport { _ in (200, completion(#"{"steps": [{"action": "press", "element": 1}]}"#)) }
    #expect(try await planner(pressesOne).plan("reply", context: screen) == [.pressElement(1)])
    let pressesNine = FakeHTTPTransport { _ in (200, completion(#"{"steps": [{"action": "press", "element": 9}]}"#)) }
    await #expect(throws: VoiceCommandError.unknownElement(9)) {
      try await planner(pressesNine).plan("reply", context: screen)
    }
  }

  @Test("a plan cut off at the token cap is never run")
  func truncated() async {
    let transport = FakeHTTPTransport { _ in
      (200, completion(#"{"steps": [{"action": "open_app", "app": "Slack"}]}"#, finishReason: "length"))
    }
    await #expect(throws: VoiceCommandError.truncatedReply) {
      try await planner(transport).plan("open slack", context: ScreenContext(appName: nil))
    }
  }
}

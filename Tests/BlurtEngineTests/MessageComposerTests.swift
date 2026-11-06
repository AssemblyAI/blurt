import Foundation
import Testing

@testable import AssemblyAI
@testable import BlurtEngine

@Suite("MessageComposer")
struct MessageComposerTests {
  private func composer(_ transport: any HTTPTransport) -> MessageComposer {
    MessageComposer(apiKeyProvider: { "raw-key" }, transport: transport)
  }

  @Test("posts one chat completion to Gemma: the instruction as system, the app and instructions tagged as user")
  func request() async throws {
    let sent = ValueBox<URLRequest?>(nil)
    let transport = FakeHTTPTransport { request in
      sent.value = request
      return (200, completion("Hey Dan, we should have a way to just speak instructions."))
    }
    let text = try await composer(transport).compose(
      "ok I'm writing a Slack reply, tell Dan we should have a feature to just speak instructions", for: "Slack")
    #expect(text == "Hey Dan, we should have a way to just speak instructions.")

    let request = try #require(sent.value)
    #expect(request.url == ReadAloudLLM.endpoint)
    #expect(request.timeoutInterval == MessageComposer.timeout)
    let body = try #require(request.httpBody)
    let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(object["model"] as? String == "gemma-4-31b")
    #expect(object["max_tokens"] as? Int == MessageComposer.maxTokens)
    let messages = try #require(object["messages"] as? [[String: String]])
    #expect(
      messages == [
        ["role": "system", "content": MessageComposer.instruction],
        [
          "role": "user",
          "content":
            "<app>Slack</app>\n\n<spoken_instructions>\n"
            + "ok I'm writing a Slack reply, tell Dan we should have a feature to just speak instructions\n"
            + "</spoken_instructions>",
        ],
      ])
  }

  @Test("with no app known, the user turn is the instructions alone")
  func noApp() {
    #expect(MessageComposer.prompt("say hi", for: nil) == "<spoken_instructions>\nsay hi\n</spoken_instructions>")
    #expect(MessageComposer.prompt("say hi", for: "") == "<spoken_instructions>\nsay hi\n</spoken_instructions>")
  }

  @Test("a composition cut off at the token cap is never handed back to paste")
  func truncated() async {
    let transport = FakeHTTPTransport { _ in (200, completion("Hey Dan, we", finishReason: "length")) }
    await #expect(throws: ReadAloudLLMError.truncated) {
      try await composer(transport).compose("tell Dan hi", for: "Slack")
    }
  }
}

import Foundation
import Testing

@testable import AssemblyAI
@testable import BlurtEngine

@Suite("SelectionRewriter")
struct SelectionRewriterTests {
  private func rewriter(_ transport: any HTTPTransport) -> SelectionRewriter {
    SelectionRewriter(apiKeyProvider: { "raw-key" }, transport: transport)
  }

  @Test("posts one chat completion to Gemma: the instruction as system, selection and request tagged as user")
  func request() async throws {
    let sent = ValueBox<URLRequest?>(nil)
    let transport = FakeHTTPTransport { request in
      sent.value = request
      return (200, completion("Dear team, the launch has moved to Friday."))
    }
    let rewrite = try await rewriter(transport).rewrite(
      "hey all launch is friday now", as: "make it more formal")
    #expect(rewrite == "Dear team, the launch has moved to Friday.")

    let request = try #require(sent.value)
    #expect(request.url == ReadAloudLLM.endpoint)
    #expect(request.timeoutInterval == SelectionRewriter.timeout)
    let body = try #require(request.httpBody)
    let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(object["model"] as? String == "gemma-4-31b")
    #expect(object["max_tokens"] as? Int == SelectionRewriter.maxTokens)
    let messages = try #require(object["messages"] as? [[String: String]])
    #expect(
      messages == [
        ["role": "system", "content": SelectionRewriter.instruction],
        [
          "role": "user",
          "content":
            "<highlighted_text>\nhey all launch is friday now\n</highlighted_text>\n\n"
            + "<spoken_request>\nmake it more formal\n</spoken_request>",
        ],
      ])
  }

  @Test("a selection past the cap fails before any request, rather than rewriting part of it")
  func tooLong() async {
    let calls = Counter()
    let transport = FakeHTTPTransport { _ in
      _ = calls.next()
      return (200, completion("x"))
    }
    let long = String(repeating: "a", count: SelectionRewriter.maxCharacters + 1)
    await #expect(throws: SelectionRewriteError.tooLong) {
      try await rewriter(transport).rewrite(long, as: "shorter")
    }
    #expect(calls.value == 0)
  }

  /// A triple-clicked line is selected with its line break, and the paste
  /// replaces the whole highlight: a rewrite that came back without it would
  /// join the line to the next one.
  @Test("only the words are sent; the whitespace around the selection comes back where it was")
  func keepsSelectionEdges() async throws {
    let sent = ValueBox<URLRequest?>(nil)
    let transport = FakeHTTPTransport { request in
      sent.value = request
      return (200, completion("Dear all,"))
    }
    let rewrite = try await rewriter(transport).rewrite("  hey all\n", as: "make it more formal")
    #expect(rewrite == "  Dear all,\n")
    let body = try #require(sent.value?.httpBody)
    let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    let messages = try #require(object["messages"] as? [[String: String]])
    #expect(messages.last?["content"]?.hasPrefix("<highlighted_text>\nhey all\n</highlighted_text>") == true)
  }

  @Test("a selection splits into the whitespace at its edges and the words between")
  func edges() {
    let line = SelectionEdges("  First line.\r\n")
    #expect(line.leading == "  " && line.words == "First line." && line.trailing == "\r\n")
    #expect(line.around("The opening line.") == "  The opening line.\r\n")
    let bare = SelectionEdges("hey all")
    #expect(bare.leading.isEmpty && bare.words == "hey all" && bare.trailing.isEmpty)
    #expect(bare.around("Dear all,") == "Dear all,")
    let blank = SelectionEdges(" \n ")
    #expect(blank.words.isEmpty && blank.around("x") == " \n x")
  }

  @Test("a rewrite cut off at the token cap is never handed back to paste")
  func truncated() async {
    let transport = FakeHTTPTransport { _ in (200, completion("Dear team, the", finishReason: "length")) }
    await #expect(throws: ReadAloudLLMError.truncated) {
      try await rewriter(transport).rewrite("hey all", as: "formal")
    }
  }
}

/// The slice of the gateway's OpenAI-shaped completion body the client reads:
/// each choice's text and why it stopped.
struct GatewayChatCompletion: Decodable {
  struct Choice: Decodable {
    struct Message: Decodable {
      let content: String?
    }

    enum CodingKeys: String, CodingKey {
      case message
      case finishReason = "finish_reason"
    }

    let message: Message
    let finishReason: String?
  }

  let choices: [Choice]
}

/// A chat completion request: the model, the turns, the token cap, the
/// temperature, and optionally a JSON schema the reply must follow.
public struct GatewayChatRequest: Encodable, Sendable {
  /// One turn of the conversation: who says it, and what.
  public struct Message: Encodable, Sendable, Equatable {
    let role: String
    let content: String

    /// `role` is the OpenAI role name: `system`, `user` or `assistant`.
    public init(role: String, content: String) {
      self.role = role
      self.content = content
    }
  }

  enum CodingKeys: String, CodingKey {
    case model
    case messages
    case temperature
    case maxTokens = "max_tokens"
    case responseFormat = "response_format"
  }

  let model: String
  let messages: [Message]
  let maxTokens: Int
  let temperature: Double
  /// A JSON schema the reply must follow, encoded as the caller's own type
  /// encodes it. Nil leaves the key off the wire.
  let responseFormat: (any Encodable & Sendable)?

  /// The request as sent; `responseFormat` nil asks for free text.
  public init(
    model: String,
    messages: [Message],
    maxTokens: Int,
    temperature: Double,
    responseFormat: (any Encodable & Sendable)? = nil
  ) {
    self.model = model
    self.messages = messages
    self.maxTokens = maxTokens
    self.temperature = temperature
    self.responseFormat = responseFormat
  }

  /// Encodes every field, leaving `response_format` off when there is none.
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(model, forKey: .model)
    try container.encode(messages, forKey: .messages)
    try container.encode(maxTokens, forKey: .maxTokens)
    try container.encode(temperature, forKey: .temperature)
    if let responseFormat {
      try container.encode(responseFormat, forKey: .responseFormat)
    }
  }
}

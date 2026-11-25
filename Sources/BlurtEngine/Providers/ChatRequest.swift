/// A chat completion, as the engine's LLM clients ask for one — read-aloud
/// (`ReadAloudLLM`), the transcript transforms (`TranscriptLLM`), the rewrite
/// and compose keys (`SelectionRewriter`, `MessageComposer`) and the command
/// key (`VoiceCommandPlanner`). Provider-neutral: a provider package turns it
/// into its own wire request (`BlurtAssemblyAI` sends it to AssemblyAI's LLM
/// Gateway).
public struct ChatRequest: Sendable, Equatable {
  /// One turn of the conversation.
  public struct Message: Sendable, Equatable {
    /// Who said it: `system`, `user` or `assistant`.
    public let role: String
    /// What was said.
    public let content: String
  }

  /// A JSON value built in code: a response format's schema.
  public indirect enum JSONValue: Encodable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([Self])
    case object([String: Self])

    /// Encodes the value as the JSON it stands for.
    public func encode(to encoder: any Encoder) throws {
      var container = encoder.singleValueContainer()
      switch self {
      case .string(let value):
        try container.encode(value)

      case .number(let value):
        try container.encode(value)

      case .bool(let value):
        try container.encode(value)

      case .array(let value):
        try container.encode(value)

      case .object(let value):
        try container.encode(value)
      }
    }
  }

  /// The model the client chose, by the name its provider knows it by.
  public let model: String
  /// The system prompt, then the turns.
  public let messages: [Message]
  /// The most tokens the reply may run to.
  public let maxTokens: Int
  /// The sampling temperature: 0 for every client, which copies or answers
  /// rather than composes.
  public let temperature: Double
  /// A JSON schema the reply must follow (`VoiceCommandPlanner`'s plan). Nil
  /// asks for free text, as every other client does.
  public internal(set) var responseFormat: JSONValue?
}

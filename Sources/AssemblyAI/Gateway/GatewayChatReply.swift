/// A chat completion's reply.
public struct GatewayChatReply: Sendable, Equatable {
  /// The first choice's text, trimmed.
  public let text: String
  /// The model stopped at `max_tokens`, part-way through.
  public let truncated: Bool
}

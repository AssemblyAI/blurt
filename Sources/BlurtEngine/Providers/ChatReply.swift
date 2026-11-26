/// A chat completion's reply.
public struct ChatReply: Sendable, Equatable {
  let text: String
  /// The model stopped at the token cap, part-way through.
  let truncated: Bool
  /// The model that answered, by its provider's name for it, for the
  /// developer-mode command log (`PlanTrace`). Nil when the provider doesn't say.
  let model: String?

  /// A reply of `text`, `truncated` when the model stopped at the token cap,
  /// from `model` when the provider names it.
  public init(text: String, truncated: Bool, model: String? = nil) {
    self.text = text
    self.truncated = truncated
    self.model = model
  }
}

/// A chat completion's reply.
public struct ChatReply: Sendable, Equatable {
  let text: String
  /// The model stopped at the token cap, part-way through.
  let truncated: Bool

  /// A reply of `text`, `truncated` when the model stopped at the token cap.
  public init(text: String, truncated: Bool) {
    self.text = text
    self.truncated = truncated
  }
}

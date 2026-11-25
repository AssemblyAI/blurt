public import Foundation

/// AssemblyAI's LLM Gateway: one `POST /v1/chat/completions`, the
/// OpenAI-shaped chat completion, answered whole.
///
/// What it deliberately doesn't hold: which model, which prompt, or what the
/// reply is for. Those are the calling app's, and arrive as the
/// `GatewayChatRequest` it builds.
public struct GatewayChatClient: Sendable {
  static let endpoint = URL(literal: "https://llm-gateway.assemblyai.com/v1/chat/completions")

  private let transport: any HTTPTransport
  private let userAgent: String?

  /// `userAgent` names the calling app; nil sends URLSession's default.
  public init(transport: any HTTPTransport = URLSession.shared, userAgent: String? = nil) {
    self.transport = transport
    self.userAgent = userAgent
  }

  /// The first choice's text, trimmed, and whether it hit the token cap. Throws
  /// when there is no text at all.
  static func reply(from data: Data) throws -> GatewayChatReply {
    guard let choice = try JSONDecoder().decode(GatewayChatCompletion.self, from: data).choices.first,
      let text = choice.message.content?.trimmedNonEmpty()
    else {
      throw GatewayChatError.empty
    }
    return GatewayChatReply(text: text, truncated: choice.finishReason == "length")
  }

  /// One chat completion: the request, the status and the reply. `timeout` is
  /// the request's idle timeout.
  public func complete(
    _ request: GatewayChatRequest,
    apiKey: String,
    timeout: TimeInterval
  ) async throws -> GatewayChatReply {
    let urlRequest = try URLRequest.jsonPost(
      to: Self.endpoint,
      apiKey: apiKey,
      userAgent: userAgent,
      timeout: timeout,
      body: request
    )
    let (data, response) = try await transport.data(for: urlRequest)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(status) else {
      throw GatewayChatError.status(status)
    }
    return try Self.reply(from: data)
  }
}

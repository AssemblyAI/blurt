import AssemblyAI
import BlurtEngine
import Foundation

/// The engine's LLM seam on AssemblyAI's LLM Gateway (`GatewayChatClient`),
/// with Blurt's key and User-Agent.
struct AssemblyAIChat: ChatCompleting {
  private let apiKeyProvider: @Sendable () -> String?
  private let client: GatewayChatClient

  init(apiKeyProvider: @escaping @Sendable () -> String?, transport: any HTTPTransport) {
    self.apiKeyProvider = apiKeyProvider
    self.client = GatewayChatClient(transport: transport, userAgent: UserAgent.current)
  }

  /// The engine's request as the gateway's wire request, field for field.
  static func wire(_ request: ChatRequest) -> GatewayChatRequest {
    GatewayChatRequest(
      model: request.model,
      messages: request.messages.map { GatewayChatRequest.Message(role: $0.role, content: $0.content) },
      maxTokens: request.maxTokens,
      temperature: request.temperature,
      responseFormat: request.responseFormat
    )
  }

  func complete(_ request: ChatRequest, timeout: TimeInterval) async throws -> ChatReply {
    guard let apiKey = apiKeyProvider(), !apiKey.isEmpty else {
      throw BlurtError.apiKeyMissing
    }
    let reply = try await client.complete(Self.wire(request), apiKey: apiKey, timeout: timeout)
    return ChatReply(text: reply.text, truncated: reply.truncated)
  }
}

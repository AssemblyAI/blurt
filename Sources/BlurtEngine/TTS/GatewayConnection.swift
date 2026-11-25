import AssemblyAI
import Foundation

/// The key and transport a gateway client sends with, as one value: what
/// `ReadAloudLLM`, `TranscriptLLM`, `SelectionRewriter` and
/// `VoiceCommandPlanner` each hold.
/// Public so a client's public `init(gateway:)` can take it; everything it
/// does stays inside the engine.
public struct GatewayConnection: Sendable {
  let apiKeyProvider: @Sendable () -> String?
  let transport: any HTTPTransport

  /// One gateway chat completion: the key check, the request, the status and
  /// the reply — the one place every gateway client's call is spelled.
  func send(_ body: ReadAloudLLM.Body, timeout: TimeInterval) async throws -> ReadAloudLLM.Reply {
    guard let apiKey = apiKeyProvider(), !apiKey.isEmpty else { throw BlurtError.apiKeyMissing }
    let request = try URLRequest.assemblyAIJSONPost(
      to: ReadAloudLLM.endpoint, apiKey: apiKey, timeout: timeout, body: body
    )
    let (data, response) = try await transport.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(status) else { throw ReadAloudLLMError.status(status) }
    return try ReadAloudLLM.reply(from: data)
  }
}

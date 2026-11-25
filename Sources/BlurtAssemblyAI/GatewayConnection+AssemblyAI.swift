import AssemblyAI
import BlurtEngine
import Foundation

extension GatewayConnection {
  /// The engine's LLM clients on AssemblyAI's LLM Gateway, with the stored key.
  static func assemblyAI(
    apiKeyProvider: @escaping @Sendable () -> String? = { APIKeyStore.current },
    transport: any HTTPTransport = URLSession.shared
  ) -> GatewayConnection {
    GatewayConnection(AssemblyAIChat(apiKeyProvider: apiKeyProvider, transport: transport))
  }
}

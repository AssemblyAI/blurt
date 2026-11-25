public import AssemblyAI
public import BlurtEngine
public import Foundation

extension GatewayClient {
  /// Any of the engine's LLM clients on AssemblyAI's LLM Gateway: the stored
  /// key and `URLSession.shared` unless told otherwise.
  @preconcurrency
  public init(
    apiKeyProvider: @escaping @Sendable () -> String? = { APIKeyStore.current },
    transport: any HTTPTransport = URLSession.shared
  ) {
    self.init(gateway: .assemblyAI(apiKeyProvider: apiKeyProvider, transport: transport))
  }
}

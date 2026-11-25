public import AssemblyAI
public import Foundation

/// A gateway client built from a `GatewayConnection`. The extension gives
/// every one the same public `init(apiKeyProvider:transport:)` — the stored
/// key, `URLSession.shared` — written once rather than per client.
public protocol GatewayClient {
  /// A client that sends its requests through `gateway`.
  init(gateway: GatewayConnection)
}

extension GatewayClient {
  /// A client over a `GatewayConnection` built from `apiKeyProvider` and
  /// `transport` — by default the stored key and `URLSession.shared`.
  @preconcurrency
  public init(
    apiKeyProvider: @escaping @Sendable () -> String? = { APIKeyStore.current },
    transport: any HTTPTransport = URLSession.shared
  ) {
    self.init(gateway: GatewayConnection(apiKeyProvider: apiKeyProvider, transport: transport))
  }
}

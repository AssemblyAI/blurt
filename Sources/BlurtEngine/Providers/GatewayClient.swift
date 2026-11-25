/// An LLM client built from a `GatewayConnection`. A provider package adds a
/// convenience init for its own service (`BlurtAssemblyAI`'s
/// `init(apiKeyProvider:transport:)`).
public protocol GatewayClient {
  /// A client that sends its requests through `gateway`.
  init(gateway: GatewayConnection)
}

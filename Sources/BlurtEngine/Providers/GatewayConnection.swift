import Foundation

/// What every LLM client in the engine sends through: the provider's
/// `ChatCompleting`, as one value each client holds. The one place a client's
/// call is spelled, so a new client can't skip it.
public struct GatewayConnection: Sendable {
  private let completer: any ChatCompleting

  /// A connection to `completer`, the provider's chat completion.
  public init(_ completer: any ChatCompleting) {
    self.completer = completer
  }

  /// One chat completion through the provider.
  func send(_ request: ChatRequest, timeout: TimeInterval) async throws -> ChatReply {
    try await completer.complete(request, timeout: timeout)
  }
}

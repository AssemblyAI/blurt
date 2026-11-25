public import Foundation

/// The LLM seam: one chat completion. A provider package conforms
/// (`BlurtAssemblyAI`'s `AssemblyAIChat`); tests play the service through it.
///
/// A conformer resolves its own credentials and throws
/// `BlurtError.apiKeyMissing` when it has none, the same way every provider
/// seam does, so the caller can tell "no key" from a failed request.
public protocol ChatCompleting: Sendable {
  /// The reply to `request`, abandoned if the response goes quiet for `timeout`.
  func complete(_ request: ChatRequest, timeout: TimeInterval) async throws -> ChatReply
}

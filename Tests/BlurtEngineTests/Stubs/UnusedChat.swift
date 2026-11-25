import Foundation
import Testing

@testable import BlurtEngine

/// An LLM no test means to reach: a router suite passes it for the clients its
/// presses never use, and a call to it fails the test that made it.
struct UnusedChat: ChatCompleting {
  func complete(_: ChatRequest, timeout _: TimeInterval) throws -> ChatReply {
    Issue.record("an LLM client this suite doesn't exercise was called")
    throw CancellationError()
  }
}

extension GatewayConnection {
  /// A connection to `UnusedChat`.
  static let unused = GatewayConnection(UnusedChat())
}

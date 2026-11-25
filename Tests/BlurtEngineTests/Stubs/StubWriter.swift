import Foundation
import Synchronization
import Testing

@testable import BlurtEngine

/// A rewriter or composer that records each call and answers with `reply`,
/// or throws `error` — or, `hangs`, writes until cancelled. Shared by the
/// rewrite and compose router suites (`StubRewriter`, `StubComposer`).
final class StubWriter<Call: Equatable & Sendable>: Sendable {
  private let reply: String
  private let error: (any Error & Sendable)?
  private let hangs: Bool
  private let recorded = Mutex<[Call]>([])

  var calls: [Call] { recorded.withLock { $0 } }

  init(reply: String = "", error: (any Error & Sendable)? = nil, hangs: Bool = false) {
    self.reply = reply
    self.error = error
    self.hangs = hangs
  }

  private func write(_ call: Call) async throws -> String {
    recorded.withLock { $0.append(call) }
    if hangs { try await Task.sleep(for: .seconds(60)) }
    if let error { throw error }
    return reply
  }
}

extension StubWriter: SelectionRewriting where Call == RewriteCall {
  func rewrite(_ selection: String, as request: String) async throws -> String {
    try await write(RewriteCall(selection: selection, request: request))
  }
}

extension StubWriter: MessageComposing where Call == ComposeCall {
  func compose(_ instructions: String, for app: String?) async throws -> String {
    try await write(ComposeCall(instructions: instructions, app: app))
  }
}

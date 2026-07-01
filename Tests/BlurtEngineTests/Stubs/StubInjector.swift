import AppKit
import Foundation

@testable import BlurtEngine

actor StubInjector: InjectorProtocol {
  var inserted: [String] = []
  /// The `priorText` passed alongside each `insert`, so tests can assert the
  /// session forwarded the captured caret context for separator decisions.
  var insertedPrior: [String?] = []
  var error: (any Error & Sendable)?

  nonisolated func insert(_ text: String, after priorText: String?) async throws {
    if let e = await self.error { throw e }
    await record(text, priorText)
  }
  nonisolated func setTargetApp(_ app: NSRunningApplication?) async {}
  private func record(_ s: String, _ prior: String?) {
    inserted.append(s)
    insertedPrior.append(prior)
  }
  func setError(_ error: (any Error & Sendable)?) { self.error = error }
}

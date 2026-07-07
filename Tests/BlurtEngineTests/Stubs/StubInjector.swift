import AppKit
import Foundation

@testable import BlurtEngine

actor StubInjector: InjectorProtocol {
  var inserted: [String] = []
  /// The `priorText` passed alongside each `insert`, so tests can assert the
  /// session forwarded the captured caret context for separator decisions.
  var insertedPrior: [String?] = []
  var error: (any Error & Sendable)?

  // Actor-isolated methods satisfy these `async` protocol requirements directly.
  func insert(_ text: String, after priorText: String?, windowTitle: String?) async throws {
    if let error { throw error }
    inserted.append(text)
    insertedPrior.append(priorText)
  }
  func setTargetApp(_ app: NSRunningApplication?) async {}
  func setError(_ error: (any Error & Sendable)?) { self.error = error }
}

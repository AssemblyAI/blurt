import Foundation

@testable import BlurtEngine

#if os(macOS)
  import AppKit
#endif

actor StubInjector: InjectorProtocol {
  var inserted: [String] = []
  /// The `priorText` and `windowTitle` passed alongside each `insert`: the two
  /// halves of the captured caret context the real injector's separator decision
  /// runs on, so a test can assert the session forwarded them — not merely that
  /// the arguments arrived, which was all a host-dependent real capture allowed.
  var insertedPrior: [String?] = []
  var insertedWindowTitles: [String?] = []
  var error: (any Error & Sendable)?

  // Actor-isolated methods satisfy these `async` protocol requirements directly.
  func insert(_ text: String, after priorText: String?, windowTitle: String?) async throws {
    if let error { throw error }
    inserted.append(text)
    insertedPrior.append(priorText)
    insertedWindowTitles.append(windowTitle)
  }
  #if os(macOS)
    func setTargetApp(_ app: NSRunningApplication?) async {}
  #endif
  func setError(_ error: (any Error & Sendable)?) { self.error = error }
}

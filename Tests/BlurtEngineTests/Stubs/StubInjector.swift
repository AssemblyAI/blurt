import Foundation

@testable import BlurtEngine

actor StubInjector: InjectorProtocol {
  var inserted: [String] = []
  /// The `priorText` and `windowTitle` passed alongside each `insert`: the two
  /// halves of the captured caret context the real injector's separator decision
  /// runs on, so a test can assert the session forwarded them — not merely that
  /// the arguments arrived, which was all a host-dependent real capture allowed.
  var insertedPrior: [String?] = []
  var insertedWindowTitles: [String?] = []
  /// The password-field verdict passed with each `insert`.
  var insertedSecurity: [TargetSecurity] = []
  var error: (any Error & Sendable)?
  /// What each `insertAtFocus` pasted: a voice command's typed step.
  var insertedAtFocus: [String] = []
  /// The pid of each `setTarget`, nil for "wherever focus is now".
  var targets: [pid_t?] = []

  // Actor-isolated methods satisfy these `async` protocol requirements directly.
  func insert(_ text: String, after priorText: String?, windowTitle: String?, security: TargetSecurity) throws {
    if let error { throw error }
    inserted.append(text)
    insertedPrior.append(priorText)
    insertedWindowTitles.append(windowTitle)
    insertedSecurity.append(security)
  }
  func insertAtFocus(_ text: String) throws {
    if let error { throw error }
    insertedAtFocus.append(text)
  }
  func setTarget(_ focus: CapturedFocus?) { targets.append(focus?.pid) }
  func setError(_ error: (any Error & Sendable)?) { self.error = error }
}

import Foundation

// The two questions the engine's catch sites ask of a failed request,
// answered once. They differ on purpose: the shape says what the error
// *looks* like, and only the current task's own flag says whether anyone
// actually cancelled. Internal: the engine imports no provider SDK, and the
// AssemblyAI SDK states the one rule it needs (`SpeechClient`) itself.
extension Error {
  /// Whether this error looks like a cancellation: Swift's `CancellationError`,
  /// or the `URLError.cancelled` that `URLSession` answers a torn-down request
  /// with. Says nothing about *who* tore it down — the system drops requests
  /// with the same code (a network switch, sleep and wake, an invalidated
  /// session), so on its own it decides nothing; `isAbandonment` does.
  var isCancellationShaped: Bool {
    self is CancellationError || (self as? URLError)?.code == .cancelled
  }

  /// Whether this error is the current task's work being abandoned: it is
  /// cancellation-shaped *and* the task reading it was cancelled. A
  /// cancellation-shaped error on a task nobody cancelled is a request the
  /// system dropped, a failure like any other — taking it for a cancel leaves
  /// whoever waits on the job's outcome waiting for one that never comes.
  ///
  /// Read it in the task that was (or wasn't) cancelled: `Task.isCancelled`
  /// is the current task's flag, so a catch inside a different, unstructured
  /// task answers for that one instead.
  var isAbandonment: Bool {
    isCancellationShaped && Task.isCancelled
  }
}

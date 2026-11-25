import Foundation
import Synchronization

/// Resumes a continuation at most once. `nonisolated` because the app target
/// defaults to the main actor, and AuthenticationServices calls the completion
/// handler on its own XPC queue: a main-actor type here trips Swift's isolation
/// check and crashes the app the moment the consent page redirects.
nonisolated final class ResumeOnce: Sendable {
  private let continuation: Mutex<CheckedContinuation<URL?, Never>?>

  init(_ continuation: CheckedContinuation<URL?, Never>) {
    self.continuation = Mutex(continuation)
  }

  func callAsFunction(_ url: URL?) {
    continuation.withLock { pending in
      pending?.resume(returning: url)
      pending = nil
    }
  }
}

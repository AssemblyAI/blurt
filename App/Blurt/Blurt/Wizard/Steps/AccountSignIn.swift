import AppKit
import AuthenticationServices
import BlurtEngine
import Synchronization

/// Runs the browser half of "Sign in with AssemblyAI": opens the consent page in
/// a web authentication session and hands the redirect to `AssemblyAIAccount`,
/// which owns everything either side of it (PKCE, the exchange, storage).
///
/// Not ephemeral on purpose: a member already signed in to the dashboard in
/// their browser only has to approve.
@MainActor
final class AccountSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
  private var session: ASWebAuthenticationSession?

  /// Signs in and reports how it ended. A closed window is `.cancelled`.
  func run(_ account: AssemblyAIAccount) async -> SignInOutcome {
    guard let authorization = account.beginSignIn(),
      let scheme = authorization.configuration.callbackScheme
    else { return .failed(.unavailable) }

    let callback: URL? = await withCheckedContinuation { continuation in
      // A session that fails to start may or may not also call its handler, and
      // a continuation resumed twice traps, so whichever comes first wins.
      let resume = ResumeOnce(continuation)
      let session = ASWebAuthenticationSession(
        url: authorization.url, callback: .customScheme(scheme)
      ) { @Sendable url, _ in
        // An error here is the user closing the window (or the session failing to
        // start); either way there is no redirect to finish.
        resume(url)
      }
      session.presentationContextProvider = self
      session.prefersEphemeralWebBrowserSession = false
      self.session = session
      if !session.start() { resume(nil) }
    }
    session = nil
    guard let callback else { return .cancelled }
    return await account.completeSignIn(authorization, callback: callback)
  }

  func cancel() {
    session?.cancel()
    session = nil
  }

  nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    MainActor.assumeIsolated {
      NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible } ?? ASPresentationAnchor()
    }
  }
}

/// Resumes a continuation at most once. `nonisolated` because the app target
/// defaults to the main actor, and AuthenticationServices calls the completion
/// handler on its own XPC queue: a main-actor type here trips Swift's isolation
/// check and crashes the app the moment the consent page redirects.
private nonisolated final class ResumeOnce: Sendable {
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

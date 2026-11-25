import AppKit
import AuthenticationServices
import BlurtEngine

/// Runs the browser half of "Sign in with AssemblyAI": opens the consent page in
/// a web authentication session and hands the redirect to `AssemblyAIAccount`,
/// which owns everything either side of it (PKCE, the exchange, storage).
///
/// Not ephemeral on purpose: a member already signed in to the dashboard in
/// their browser only has to approve.
final class AccountSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
  private var session: ASWebAuthenticationSession?

  /// Signs in and reports how it ended. A closed window is `.cancelled`.
  func run(_ account: AssemblyAIAccount) async -> SignInOutcome {
    guard let authorization = account.beginSignIn(),
      let scheme = authorization.configuration.callbackScheme
    else {
      return .failed(.unavailable)
    }

    let callback: URL? = await withCheckedContinuation { continuation in
      // A session that fails to start may or may not also call its handler, and
      // a continuation resumed twice traps, so whichever comes first wins.
      let resume = ResumeOnce(continuation)
      let authSession = ASWebAuthenticationSession(
        url: authorization.url, callback: .customScheme(scheme)
      ) { @Sendable url, _ in
        // An error here is the user closing the window (or the session failing to
        // start); either way there is no redirect to finish.
        resume(url)
      }
      authSession.presentationContextProvider = self
      authSession.prefersEphemeralWebBrowserSession = false
      session = authSession
      if !authSession.start() { resume(nil) }
    }
    session = nil
    guard let callback else {
      return .cancelled
    }
    return await account.completeSignIn(authorization, callback: callback)
  }

  func cancel() {
    session?.cancel()
    session = nil
  }

  nonisolated func presentationAnchor(for _: ASWebAuthenticationSession) -> ASPresentationAnchor {
    MainActor.assumeIsolated {
      NSApp.keyWindow ?? NSApp.windows.first(where: \.isVisible) ?? ASPresentationAnchor()
    }
  }
}

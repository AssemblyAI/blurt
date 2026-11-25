/// How a sign-in attempt ended.
public enum SignInOutcome: Sendable, Equatable {
  case signedIn
  /// The member closed the window or declined on the consent page. Nothing to
  /// report.
  case cancelled
  case failed(SignInFailure)
}

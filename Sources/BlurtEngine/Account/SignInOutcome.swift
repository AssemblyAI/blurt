import AssemblyAI

/// How a sign-in attempt ended.
public enum SignInOutcome: Sendable, Equatable {
  case signedIn
  /// The member closed the window or declined on the consent page. Nothing to
  /// report.
  case cancelled
  case failed(SignInFailure)
}

/// Why a sign-in failed, with the wording the shell shows. Owned here, next to
/// the outcomes, so the shell renders one judgement instead of assembling text
/// at an alert call site no test reaches.
public enum SignInFailure: Sendable, Equatable {
  /// This build has no Connected App configured.
  case unavailable
  /// The redirect didn't answer this attempt or reported an error.
  case consent
  /// The exchange refused this member; carries the server's reason.
  case forbidden(String?)
  /// A credential was refused mid-flow (an expired code, a revoked grant).
  case rejected
  /// Couldn't reach AssemblyAI, or it failed.
  case server
  /// The key or the session couldn't be written to the Keychain.
  case keychain

  init(_ failure: OAuthClient.Failure) {
    switch failure {
    case .rejected: self = .rejected
    case .forbidden(let reason): self = .forbidden(reason)
    case .unreachable: self = .server
    }
  }

  /// How to report it: inline beside the row for anything a retry (or an admin)
  /// can fix, an alert only for the Keychain fault retrying can't touch. The
  /// same split `APIKeySubmission.Outcome.failureReport` makes for a pasted key.
  public var failureReport: APIKeySubmission.FailureReport {
    switch self {
    case .keychain: .alert(title: "Couldn’t Save Your Sign-In", message: message)
    default: .inline(message: message)
    }
  }

  var message: String {
    switch self {
    case .unavailable:
      "Signing in isn’t available in this version of Blurt. Use an API key instead."
    case .consent, .rejected:
      "AssemblyAI didn’t complete the sign-in. Try again."
    case .forbidden(let reason):
      reason.map { "AssemblyAI didn’t allow it: \($0)" }
        ?? "AssemblyAI didn’t allow Blurt to use your account. Ask an admin of your organization."
    case .server:
      APIKeySubmission.unreachableMessage
    case .keychain:
      "Blurt couldn’t write to your macOS Keychain. Check Keychain access and try again."
    }
  }
}

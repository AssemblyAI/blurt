extension AssemblyAIAccount {
  /// Whether the member is signed in, as the account row shows it.
  public enum Status: Sendable, Equatable {
    case signedOut
    /// `email` is nil when the ID token didn't carry one.
    case signedIn(email: String?)

    /// The account row's text while signed in; nil while signed out, when the
    /// row shows only its button.
    public var statusText: String? {
      switch self {
      case .signedOut:
        nil

      case .signedIn(let email?):
        "Signed in as \(email)"

      case .signedIn(nil):
        "Signed in"
      }
    }
  }
}

/// Which rows the AssemblyAI section shows and which button is its primary
/// action, from the stored key, whether sign-in is configured, and whether a
/// session exists. A pure projection in the engine, like `APIKeyDisplay`, so the
/// rule is tested rather than spread across two SwiftUI files.
public struct CredentialRows: Sendable, Equatable {
  public enum Primary: Sendable, Equatable {
    /// "Sign In with AssemblyAI…" is filled.
    case signIn
    /// The key row's "Connect…" is filled.
    case connect
  }

  /// The account row: offered where sign-in is configured, and kept for a
  /// session inherited by a build without it, so its Sign Out stays reachable.
  public let showsAccountRow: Bool
  /// The key row. Pasting a key is the legacy path: a new install where
  /// sign-in is configured signs in, and the row is only for an install that
  /// already has a pasted key (to change or remove it) or a build with no
  /// sign-in at all. Hidden while signed in, since the key is then the
  /// connection's to rotate.
  public let showsKeyRow: Bool
  /// The filled button, or nil once a key is stored (nothing is waiting on the
  /// user, and a lone filled button would mark a rare errand as the main action).
  public let primary: Primary?

  public static func resolve(
    isKeyStored: Bool, isSignInAvailable: Bool, status: AssemblyAIAccount.Status
  ) -> CredentialRows {
    let signedIn = status != .signedOut
    let primary: Primary? =
      signedIn || isKeyStored ? nil : (isSignInAvailable ? .signIn : .connect)
    return CredentialRows(
      showsAccountRow: isSignInAvailable || signedIn,
      showsKeyRow: !signedIn && (isKeyStored || !isSignInAvailable), primary: primary)
  }
}

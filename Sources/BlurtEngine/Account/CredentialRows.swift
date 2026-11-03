/// What the AssemblyAI section draws, from the stored key, whether sign-in is
/// configured, and whether a session exists. A pure projection in the engine,
/// like `APIKeyDisplay`, so the rule is tested rather than spread across two
/// SwiftUI files — the view switches on it and combines nothing itself.
///
/// Pasting a key is a first-class alternative to signing in, not a legacy path:
/// a team rolling Blurt out shares one key rather than adding every member to
/// its AssemblyAI account, so it is on offer whenever the user isn't signed in.
public enum CredentialRows: Sendable, Equatable {
  /// Nothing connected and sign-in configured: one "Connect to AssemblyAI" row
  /// carrying both ways in, "Use API Key…" beside a filled "Sign In…". Two rows
  /// each with a button read as two steps, and a team member who was handed a
  /// key went looking for an account they'll never have.
  case choice
  /// The key row alone: a pasted key (to change), or a build with no sign-in,
  /// where its "Connect…" is filled until a key is stored. No "Sign In…"
  /// beside a stored key — it read as a step still to do on an install that
  /// was already connected.
  case keyRow(connectIsPrimary: Bool)
  /// The account row alone: signed in, the key then being the connection's to
  /// rotate. Also a session inherited by a build without sign-in, so its Sign
  /// Out stays reachable.
  case accountRow

  public static func resolve(
    isKeyStored: Bool, isSignInAvailable: Bool, status: AssemblyAIAccount.Status
  ) -> CredentialRows {
    if status != .signedOut { return .accountRow }
    if isSignInAvailable && !isKeyStored { return .choice }
    return .keyRow(connectIsPrimary: !isKeyStored)
  }

  /// The `.choice` row's title, subtitle and key button. Here rather than in
  /// the view for the reason `APIKeyDisplay` owns the key row's wording.
  public static let choiceTitle = "Connect to AssemblyAI"
  public static let choiceSubtitle = "Sign in, or use an API key. Either works."
  public static let choiceKeyButtonTitle = "Use API Key…"
}

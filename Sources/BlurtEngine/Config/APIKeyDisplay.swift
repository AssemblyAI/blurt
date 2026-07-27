/// How the stored AssemblyAI key is presented in the setup/settings account
/// row — and the wording of the controls around it.
///
/// The engine already owns everything else about the key (`APIKeyStore`,
/// `APIKeyGateway`, `APIKeySubmission`, `APIKeyValidator`); this is the display
/// projection of it, owned here for the same reason as `OverlayUIState`: it's a
/// pure mapping from state to wording, and the SwiftUI shell that renders it has
/// no test target.
///
/// The masking rule is the part that most wants a test. A stored key is a
/// secret, and revealing a fixed-length tail of it only distinguishes two
/// accounts while the key is comfortably longer than that tail — below that,
/// "the last four characters" and "the whole key" are the same string.
public enum APIKeyDisplay: Equatable, Sendable {
  /// No key is stored.
  case notConnected
  /// A key is stored. `maskedTail` is `••••` plus its last few characters, or
  /// `nil` when the key is too short to reveal any of it (see
  /// `minimumLengthToMask`) — the row then says just "Connected".
  case connected(maskedTail: String?)

  /// How many trailing characters a masked key reveals: enough to tell two
  /// accounts apart, not enough to be useful to anyone reading the screen.
  public static let revealedTailLength = 4

  /// Shortest stored key that gets a revealed tail at all. Twice the tail, so at
  /// least half the key always stays hidden — a real AssemblyAI key is far
  /// longer, and a short one is a typo or a test fixture rather than a
  /// credential worth identifying by its ending.
  public static let minimumLengthToMask = revealedTailLength * 2

  /// Resolves what to show for the stored key. Trims first (the engine's shared
  /// rule), so a whitespace-only value reads as no key at all — the same way
  /// `APIKeyGateway` treats it.
  public static func resolve(key: String?) -> APIKeyDisplay {
    guard let key = key?.trimmedNonEmpty() else { return .notConnected }
    guard key.count >= minimumLengthToMask else { return .connected(maskedTail: nil) }
    return .connected(maskedTail: "••••\(key.suffix(revealedTailLength))")
  }

  /// Whether a key is stored. Drives the first-connect vs. rotate wording below
  /// and the row's accessibility identifiers.
  public var isConnected: Bool {
    switch self {
    case .notConnected: false
    case .connected: true
    }
  }

  /// The row's status text: the masked key once one exists (an *identity* — the
  /// question a checkmark can't answer), otherwise plain prose.
  public var statusText: String {
    switch self {
    case .notConnected: "Not connected"
    case .connected(let maskedTail): maskedTail ?? "Connected"
    }
  }

  /// Whether `statusText` is an identifier rather than prose, so the shell knows
  /// to monospace it (the revealed characters line up as a key ending instead of
  /// reading as a sentence). False for the bare "Connected"/"Not connected".
  public var rendersIdentifier: Bool {
    switch self {
    case .connected(let maskedTail): maskedTail != nil
    case .notConnected: false
    }
  }

  /// Spoken by VoiceOver: the bullets are decoration, so spell the state out.
  /// Owned here alongside `statusText` so the two can't describe different
  /// things — the same split as `OverlayUIState.accessibilityLabel`.
  public var accessibilityLabel: String {
    switch self {
    case .notConnected: "Not connected"
    case .connected(let maskedTail):
      // Drop the mask bullets and name just the revealed characters, which is
      // what a screen-reader user needs to identify the account.
      maskedTail.map { "Connected, key ending \($0.suffix(Self.revealedTailLength))" }
        ?? "Connected"
    }
  }

  /// Title of the row's button. Carries an ellipsis because it opens a sheet
  /// that needs more input before the action completes — the same rule that
  /// gives "Open Accessibility Settings…" its ellipsis.
  public var editButtonTitle: String {
    isConnected ? "Change…" : "Connect…"
  }

  /// Title of the sheet's default action. "Save" would describe storage; the
  /// operation is really verify-then-store, and on first run it's a connection.
  public var commitButtonTitle: String {
    isConnected ? "Update" : "Connect"
  }

  /// The sheet's headline explanation — why a key is needed on first run, what
  /// pasting one does once a key already exists.
  public var rationale: String {
    isConnected
      ? "Paste a new key to replace the one Blurt is using."
      : "Blurt needs an AssemblyAI API key to transcribe your speech. A free-tier key works."
  }
}

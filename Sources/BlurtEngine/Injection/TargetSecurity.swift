// periphery:ignore - public for the iPhone's keyboard relay (App/BlurtiOS), which the Mac scan doesn't index.
/// What the press-time Accessibility read says about whether the target is a
/// password field (`PressContext.targetSecurity`). One verdict for every
/// decision that guards a password: whether the dictation is remembered,
/// whether the developer-mode log keeps it, and how the injector leaves it on
/// the clipboard when the paste can't land (`InjectorProtocol.insert`).
public enum TargetSecurity: Sendable, Equatable {
  /// The read landed and the field is an ordinary one: remember the dictation
  /// and replay it as later request context.
  case ordinary
  /// The read refused the field (`FocusCapture.mustRedactContents`): the
  /// dictation is the secret, so it is not remembered at all.
  case secure
  /// Nothing is known — the read has not landed (a slow or beachballing
  /// frontmost app), or it reached no focused element
  /// (`FocusedFieldContext.unreachable`). Remembered for the Recent
  /// list, which stays on this Mac, but never replayed in `stt_prompt`, where
  /// a password would leave it.
  case unknown

  /// How long a concealed leave-behind stays on the clipboard for the paste by
  /// hand before it is cleared — a password manager's own copy window. One
  /// value for both platforms: the Mac's `SystemClipboard` and the iPhone's
  /// keyboard relay.
  public static let concealedClipboardLifetime: Duration = .seconds(90)

  /// Whether words left on the clipboard for this target are left as a secret
  /// (`ClipboardAccess.write`'s `concealed`). A password field's always are. An
  /// unknown target's are when the app is AX-opaque — a browser or Electron
  /// app, whose login form is as invisible to Accessibility as its chat box, so
  /// "unknown" there may well be a password. Elsewhere a password field is
  /// readable as one, so "unknown" means no field was focused at all — the
  /// everyday dictate-to-clipboard copy, which stays an ordinary copy a
  /// clipboard manager may keep.
  public func conceals(inAXOpaqueApp opaque: Bool) -> Bool {
    switch self {
    case .secure:
      true

    case .unknown:
      opaque

    case .ordinary:
      false
    }
  }
}

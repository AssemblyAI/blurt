import AppKit

public protocol InjectorProtocol: Sendable {
  func setTargetApp(_ app: NSRunningApplication?) async
  /// Insert text into whatever the OS currently treats as the focus target.
  /// `priorText` is the text immediately before the caret (captured at press time),
  /// used to decide whether a separating space is needed so consecutive dictations
  /// don't run together; nil when the field is empty or its contents are opaque.
  /// `windowTitle` is the focused window's title at that same press-time capture —
  /// used to recognize a *continuing* dictation into the same window when
  /// `priorText` is unreadable (see `KeyInjector.separatorBasis`); nil when the
  /// window exposes no title.
  func insert(_ text: String, after priorText: String?, windowTitle: String?) async throws
}

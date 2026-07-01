import AppKit

public protocol InjectorProtocol: Sendable {
  func setTargetApp(_ app: NSRunningApplication?) async
  /// Insert text into whatever the OS currently treats as the focus target.
  /// `priorText` is the text immediately before the caret (captured at press time),
  /// used to decide whether a separating space is needed so consecutive dictations
  /// don't run together; nil when the field is empty or its contents are opaque.
  func insert(_ text: String, after priorText: String?) async throws
}

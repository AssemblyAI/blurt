/// A failure's reason written out on the pill, in two parts so the shell can
/// truncate the subject (a device name of any length) and never the predicate,
/// which is what says what went wrong. A status line, so no closing period.
public struct PillNotice: Equatable, Sendable {
  public let subject: String
  public let predicate: String

  /// The one line it reads as — what the shell measures.
  public var text: String { "\(subject) \(predicate)" }

  public init(subject: String, predicate: String) {
    self.subject = subject
    self.predicate = predicate
  }
}

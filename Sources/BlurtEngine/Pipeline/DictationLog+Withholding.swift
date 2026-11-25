// What the developer-mode log keeps in place of a transcript it must not hold:
// one dictated into a password field, or into a field that couldn't be checked
// for one (`TargetSecurity`). The placeholders and the rule that picks between
// them live together, so the pipeline and `makeEntry` can't disagree on them.
extension DictationLog {
  /// What an entry holds in place of a transcript dictated into a password field.
  static let withheldTranscript = "(withheld: dictated into a password field)"

  /// What an entry holds in place of a transcript dictated into a field that
  /// could not be checked for a password (`TargetSecurity.unknown`).
  static let unverifiedTranscript = "(withheld: the field could not be checked for a password)"

  /// What the log may keep of `text` dictated into a target of `security`: the
  /// words only for an ordinary field; a password field's are withheld, and an
  /// unknown target's too, since a read that never landed leaves nothing to
  /// decide from. `makeEntry`'s secure check is the backstop.
  static func loggable(_ text: String, security: TargetSecurity) -> String {
    switch security {
    case .secure:
      withheldTranscript

    case .unknown:
      unverifiedTranscript

    case .ordinary:
      text
    }
  }
}

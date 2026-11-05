import Foundation
import os

nonisolated extension BlurtShared {
  /// The unified-logging subsystem both processes log under, so one predicate
  /// reads the app's lines and the keyboard's together. The app sets the
  /// same string on `HostIdentity`; the keyboard never configures one, so
  /// `KeyboardLog` names it here.
  package static let logSubsystem = "com.assemblyai.blurt.iphone"
}

/// The keyboard's log: one line per thing the keyboard does with the app, so
/// a phone's log archive tells the whole story of a press from the keyboard's
/// side — which process and controller was up, what the readiness record said
/// at the tap, what was written, what came back, and what became of the
/// words. Every field is public: ids and outcomes, never the user's text.
/// Read with `log show --predicate 'subsystem == "com.assemblyai.blurt.iphone"
/// AND category == "Keyboard"'`.
package nonisolated enum KeyboardLog {
  package static let category = "Keyboard"
  private static let logger = Logger(subsystem: BlurtShared.logSubsystem, category: category)

  package static func appeared(pid: Int32, process: String, controller: String, fullAccess: Bool) {
    logger.info(
      """
      appeared pid=\(pid, privacy: .public) process=\(process, privacy: .public) \
      controller=\(controller, privacy: .public) fullAccess=\(fullAccess, privacy: .public)
      """)
  }

  package static func disappeared(pid: Int32, process: String, controller: String) {
    logger.info(
      """
      disappeared pid=\(pid, privacy: .public) process=\(process, privacy: .public) \
      controller=\(controller, privacy: .public)
      """)
  }

  package static func hostLeaving(process: String, controller: String) {
    logger.info("host leaving process=\(process, privacy: .public) controller=\(controller, privacy: .public)")
  }

  /// The readiness record as the tap read it.
  package static func readiness(sequence: UInt64?, ready: Bool, reason: FailureReason?) {
    logger.info(
      """
      tap: record sequence=\(sequence.map { "\($0)" } ?? "none", privacy: .public) \
      ready=\(ready, privacy: .public) reason=\(reason?.rawValue ?? "none", privacy: .public)
      """)
  }

  package static func wrote(_ command: KeyboardCommand, resend: Bool) {
    logger.info(
      """
      \(resend ? "resent" : "wrote", privacy: .public) \(command.kind.rawValue, privacy: .public) \
      id=\(command.id.uuidString, privacy: .public) seq=\(command.seq ?? 0, privacy: .public) \
      dictation=\(command.dictationID?.uuidString ?? "none", privacy: .public) \
      state=\(command.stateSequence.map { "\($0)" } ?? "none", privacy: .public)
      """)
  }

  package static func ack(_ ack: CommandAck) {
    logger.info(
      """
      ack id=\(ack.commandID.uuidString, privacy: .public) \
      outcome=\(String(describing: ack.outcome), privacy: .public)
      """)
  }

  package static func deadline(command: UUID, reason: FailureReason) {
    logger.info(
      "deadline id=\(command.uuidString, privacy: .public) → \(reason.rawValue, privacy: .public)")
  }

  package static func refused(_ reason: FailureReason) {
    logger.info("press refused: \(reason.rawValue, privacy: .public)")
  }

  package static func hop(_ url: URL) {
    logger.info("hop \(url.absoluteString, privacy: .public)")
  }

  package static func result(_ id: UUID, inserted: Bool, why: String) {
    logger.info(
      """
      result id=\(id.uuidString, privacy: .public) \(inserted ? "inserted" : "skipped", privacy: .public): \
      \(why, privacy: .public)
      """)
  }
}

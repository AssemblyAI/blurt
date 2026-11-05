import Foundation

/// This keyboard process, as the app knows it. iOS runs the keyboard as an
/// extension process it starts and kills without a word, so the id is drawn
/// once per process and rides every command and every presence record
/// (`KeyboardCommand.keyboard`, `KeyboardPresenceRecord.processID`): the app
/// answers the press to the process that made it, addresses the words back
/// to it, and releases a dictation whose process is gone. A controller
/// (`KeyboardModel.controllerID`) is one host field within the process.
package nonisolated enum KeyboardProcess {
  package static let id = UUID().uuidString

  /// The next command's sequence number: one counter per process, so the app
  /// can tell a resend (the same id and number again) from a new command.
  @MainActor private static var lastSequence: UInt64 = 0

  @MainActor package static func nextSequence() -> UInt64 {
    lastSequence += 1
    return lastSequence
  }
}

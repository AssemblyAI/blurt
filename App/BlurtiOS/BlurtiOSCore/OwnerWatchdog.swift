import Foundation

/// Ends a dictation whose keyboard is gone. iOS kills a keyboard extension
/// without a word — the host app left, memory ran short — and a recording
/// with nobody to send the release would run to the engine's cap with the
/// microphone open. So while a dictation is in flight, the coordinator asks
/// this every keyboard beat and on the `keyboard` signal, and a yes is a
/// release: the words are kept and go to the clipboard, as they would with
/// no keyboard to take them.
///
/// The rule is owner-based. The one presence record says which keyboard
/// process is on screen; the dictation stays alive only while that record
/// is the owner's, says `onScreen`, and is younger than
/// `BlurtShared.ownerWatchdog` — two keyboard beats and grace. Another
/// keyboard on screen does not keep it alive: the owner is the process whose
/// press started it and whose field the words are for, and if it is gone the
/// words have nowhere to go. (The keyboard on screen may still *end* the
/// dictation, through `CommandRouter`; it just does not stand in for the
/// owner here.) A dictation with no owner on record — a press that carried
/// no process id — has nobody to wait for, so whoever is on screen stands
/// in, and it is released once no keyboard is.
package nonisolated enum OwnerWatchdog {
  /// Whether the dictation in flight has lost its keyboard.
  package static func shouldRelease(inFlight: DictationRef?, presence: KeyboardPresenceRecord?, now: Date) -> Bool {
    guard let inFlight else { return false }
    guard let presence, presence.onScreen, stands(presence, for: inFlight) else { return true }
    return now.timeIntervalSince(presence.seenAt) > BlurtShared.ownerWatchdog
  }

  /// The record is the owner's, or the dictation has no owner to be stricter about.
  private static func stands(_ presence: KeyboardPresenceRecord, for inFlight: DictationRef) -> Bool {
    guard let owner = inFlight.ownerProcessID else { return true }
    return presence.processID == owner
  }
}

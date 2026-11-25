/// Whether Blurt may send a player Apple Events: the answer of
/// `AEDeterminePermissionToAutomateTarget`, asked *without* prompting before
/// every pause, so a dictation never puts macOS's consent prompt up mid-sentence
/// and never scripts a player that isn't running. Only the switch turning on (or
/// its "Allow" button) asks with the prompt.
public enum AutomationConsent: Equatable, Sendable {
  case granted
  /// The user declined; only System Settings can undo it.
  case denied
  /// Running, never asked: scripting it would put the prompt up.
  case notAsked
  case notRunning
  /// Any other status, kept for the log.
  case unknown(Int32)

  /// `noErr`, `errAEEventNotPermitted` (-1743), `errAEEventWouldRequireUserConsent`
  /// (-1744) and `procNotFound` (-600), as `AEDeterminePermissionToAutomateTarget`
  /// returns them.
  public init(status: Int32) {
    switch status {
    case 0:
      self = .granted

    case -1_743:
      self = .denied

    case -1_744:
      self = .notAsked

    case -600:
      self = .notRunning

    default:
      self = .unknown(status)
    }
  }
}

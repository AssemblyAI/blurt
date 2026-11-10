import BlurtiOSCore
import KeyboardKit

/// Blurt's seam in KeyboardKit's action handling. KeyboardKit types, shifts,
/// deletes, turns the pages and runs the callouts exactly as Apple's keyboard
/// does; this steps in for three things of Blurt's own: the mic key, which is
/// `KeyboardModel`'s press and lift (`PressHandshake`); the key-term field,
/// which takes the keys' characters while it is open; and the one-tap undo of
/// a dictation, where delete right after the words landed takes all of them
/// back. Everything else goes to the standard handler, and the model is told
/// when the host's text was edited so the chip and the undo follow it.
final class BlurtActionHandler: StandardKeyboardActionHandler {
  /// Set right after `init(controller:)`: a convenience initialiser cannot
  /// take a stored property, and the standard handler has no designated one
  /// short of its whole service list.
  var model: BlurtiOSCore.KeyboardModel?
  /// The mic's finger is down: a lift anywhere — off the key too — is a lift.
  private var micPressed = false

  override func handle(_ gesture: Keyboard.Gesture, on action: KeyboardAction) {
    guard let model else { return super.handle(gesture, on: action) }
    if action == .blurtMic { return handleMic(gesture, model: model) }
    if model.termDraft != nil, routeToTerm(gesture, on: action, model: model) { return }
    if gesture == .press, action == .backspace, model.undoLastInsertion() {
      triggerFeedback(for: gesture, on: action)
      return
    }
    super.handle(gesture, on: action)
    if Self.editsHost(gesture, on: action) { model.hostEdited() }
  }

  /// The mic: finger down presses, finger up lifts — tap against hold is the
  /// handshake's to decide from the stamps. The key clicks on the press as
  /// every key does; what the dictation does from there has its own haptics
  /// (`KeyboardModel+Phase`).
  private func handleMic(_ gesture: Keyboard.Gesture, model: BlurtiOSCore.KeyboardModel) {
    switch gesture {
    case .press:
      triggerFeedback(for: gesture, on: .blurtMic)
      micPressed = true
      model.micDown()
    case .release, .end:
      guard micPressed else { return }
      micPressed = false
      model.micUp()
    default:
      break
    }
  }

  /// While the term field is open the keys type into it, not the host:
  /// characters, space and return on the release KeyboardKit acts on, delete
  /// on its press and its repeat. Shift and the page keys fall through, so
  /// the pages still turn; the case follows the term's own rule.
  private func routeToTerm(
    _ gesture: Keyboard.Gesture, on action: KeyboardAction, model: BlurtiOSCore.KeyboardModel
  ) -> Bool {
    switch (gesture, action) {
    case (.release, .character(let character)): model.termType(character)
    case (.release, .space): model.termSpace()
    case (.press, .backspace), (.repeatPress, .backspace): model.termDelete()
    case (.release, .primary): model.termReturn()
    default: return false
    }
    keyboardContext.keyboardCase = model.termWantsUppercase ? .uppercased : .lowercased
    return true
  }

  /// The gestures on which the standard handler edits the host's text.
  private static func editsHost(_ gesture: Keyboard.Gesture, on action: KeyboardAction) -> Bool {
    switch (gesture, action) {
    case (.release, .character), (.release, .space), (.release, .primary), (.release, .emoji), (.release, .text),
      (.press, .backspace), (.repeatPress, .backspace):
      true
    default:
      false
    }
  }
}

import Foundation

enum VoiceCommandError: Error, Equatable, LocalizedError {
  /// The model planned nothing: the command isn't one these steps can do.
  case notUnderstood
  /// What was said is longer than any command (`VoiceCommandStep.maxCommandWords`):
  /// a key held while a video or a call played, never sent to plan.
  case commandTooLong
  /// The reply wasn't the JSON the instruction asks for.
  case malformedReply
  /// The reply stopped at the token cap, part-way through the plan.
  case truncatedReply
  case unsupportedAction(String)
  /// An `open_url` whose scheme isn't in `VoiceCommandStep.allowedSchemes`.
  case unsafeURL(String)
  case unknownShortcut(String)
  case tooManySteps
  case appNotFound(String)
  case appNotRunning(String)
  /// No pressable element by that name in the frontmost window.
  case buttonNotFound(String)
  /// No menu-bar item at that path in the frontmost app.
  case menuItemNotFound([String])
  /// A `press` or `focus` step named a number the snapshot didn't list.
  case unknownElement(Int)
  /// An element step on an element whose kind doesn't take it (`select` on a button).
  case wrongKind(action: String, id: Int, kind: String)
  /// The same step planned twice running, where repeating it isn't the point.
  case repeatedStep(String)
  /// The app in front changed between the snapshot and an element step.
  case screenChanged
  /// The listed element went away, or doesn't take the step (focus on a button).
  case elementGone
  /// A step the code refuses whatever the plan says (`DestructiveGuard`).
  case refused(String)
  /// The system refused the step (a URL nothing opened, an event not built).
  case couldNotPerform(String)

  var errorDescription: String? {
    switch self {
    case .notUnderstood:
      "Blurt can’t do that command."

    case .commandTooLong:
      "That was too long to be a command."

    case .malformedReply:
      "The LLM Gateway’s plan for that command couldn’t be read."

    case .truncatedReply:
      "The LLM Gateway’s plan for that command was cut short."

    case .unsupportedAction(let action):
      "The command needed an action Blurt doesn’t have (\(action))."

    case .unsafeURL(let url):
      "Blurt doesn’t open links like \(url)."

    case .unknownShortcut(let keys):
      "Blurt doesn’t know the shortcut \(keys)."

    case .tooManySteps:
      "That command has too many steps."

    case .appNotFound(let name):
      "No app named \(name) is installed."

    case .appNotRunning(let name):
      "\(name) isn’t open."

    case .buttonNotFound(let name):
      "There’s no \(name) button in the window in front."

    case .menuItemNotFound(let path):
      "There’s no \(path.joined(separator: " › ")) menu item."

    case .couldNotPerform(let what):
      "Blurt couldn’t \(what)."

    case .refused(let what):
      "Blurt won’t \(what)."

    case .unknownElement(let id):
      "The plan named element \(id), which isn’t on screen."

    case let .wrongKind(action, id, kind):
      "The plan used \(action) on element \(id), a \(kind); \(action) takes "
        + Self.kindsTaken(by: action) + "."
        // The mistake the model makes most: words into a field by set_value.
        + (ScreenSnapshot.kinds(of: ScreenSnapshot.textEntryRoles).contains(kind)
          ? " To put words in a \(kind), focus it, then type them." : "")

    case .repeatedStep(let action):
      "The plan repeated a \(action) step."

    case .screenChanged:
      "The window changed before Blurt got to it."

    case .elementGone:
      "That control isn’t there any more."
    }
  }

  /// The case's name for the public log, never its payload: an exhaustive
  /// switch, so a new case can't ship without one (as `BlurtError.diagnosticName`).
  var logName: String {
    switch self {
    case .notUnderstood:
      "notUnderstood"

    case .commandTooLong:
      "commandTooLong"

    case .malformedReply:
      "malformedReply"

    case .truncatedReply:
      "truncatedReply"

    case .unsupportedAction:
      "unsupportedAction"

    case .unsafeURL:
      "unsafeURL"

    case .unknownShortcut:
      "unknownShortcut"

    case .tooManySteps:
      "tooManySteps"

    case .appNotFound:
      "appNotFound"

    case .appNotRunning:
      "appNotRunning"

    case .buttonNotFound:
      "buttonNotFound"

    case .menuItemNotFound:
      "menuItemNotFound"

    case .unknownElement:
      "unknownElement"

    case .wrongKind:
      "wrongKind"

    case .repeatedStep:
      "repeatedStep"

    case .screenChanged:
      "screenChanged"

    case .elementGone:
      "elementGone"

    case .refused:
      "refused"

    case .couldNotPerform:
      "couldNotPerform"
    }
  }

  /// Whether the planner asks again once, showing the model this error: the
  /// plan was unusable rather than deliberate. Not an empty plan (the model's
  /// own "can't"), a refusal (the code's own "won't"), a cut-off reply, or an
  /// unknown action — the schema's enum rules that out, so it can't recur.
  var isRetryable: Bool {
    switch self {
    case .malformedReply, .unsafeURL, .unknownShortcut, .tooManySteps, .unknownElement, .wrongKind, .repeatedStep:
      true

    default:
      false
    }
  }

  /// The words on the pill for the failures a user can act on: the app name
  /// is the diagnosis, so it goes on the pill rather than behind a hover.
  var pillNotice: PillNotice? {
    switch self {
    case .notUnderstood:
      PillNotice(subject: "Blurt can’t", predicate: "do that")

    case .commandTooLong:
      PillNotice(subject: "Too long", predicate: "for a command")

    case .refused:
      PillNotice(subject: "Blurt won’t", predicate: "do that")

    case .appNotFound(let name):
      PillNotice(subject: name, predicate: "isn’t installed")

    case .appNotRunning(let name):
      PillNotice(subject: name, predicate: "isn’t open")

    case .buttonNotFound(let name):
      PillNotice(subject: name, predicate: "isn’t on screen")

    case .menuItemNotFound(let path):
      PillNotice(subject: path.last ?? "That item", predicate: "isn’t in the menus")

    default:
      nil
    }
  }

  /// The kinds the action named `action` takes, listed for the model; "another
  /// kind" when the name isn't an action or takes no particular kind.
  private static func kindsTaken(by action: String) -> String {
    let kinds = VoiceCommandStep.Action(rawValue: action).flatMap { VoiceCommandStep.kinds[$0] }
    return kinds?.sorted().joined(separator: ", ") ?? "another kind"
  }
}

/// What one trigger key is set to in the Keys tab. Persisted as a string
/// (`raw`, `init(raw:)`) in `TriggerKeyStyleStore`'s map; everywhere else it's
/// this type, so a choice is matched by the compiler rather than by string.
public enum TriggerKeyChoice: Hashable, Sendable {
  case off
  /// Dictates with `style`: a profile's `uuidString`,
  /// `StyleProfileStore.defaultStyleID` for base styling, or
  /// `mainWindowStyle` for whatever the main window has selected.
  case dictate(style: String)
  case readAloud
  case ask
  case rewrite
  case compose
  case command

  /// The style id for "use the main window's selection". Not a UUID, and not
  /// `StyleProfileStore.defaultStyleID`, so it can collide with neither.
  public static let mainWindowStyle = "current"
  /// Dictating with the main window's selection: the bound key's default.
  public static let dictate = Self.dictate(style: mainWindowStyle)

  public var action: TriggerKeyAction {
    switch self {
    case .off:
      .off

    case .dictate:
      .dictate

    case .readAloud:
      .readAloud

    case .ask:
      .ask

    case .rewrite:
      .rewrite

    case .compose:
      .compose

    case .command:
      .command
    }
  }

  var raw: String {
    switch self {
    case .off:
      ""

    case .dictate(let style):
      style

    case .readAloud:
      "read-aloud"

    case .ask:
      "ask"

    case .rewrite:
      "rewrite"

    case .compose:
      "compose"

    case .command:
      "command"
    }
  }

  /// The stored form. Any string that isn't one of the action markers is a
  /// style id — the encoding from before read, ask, rewrite, compose and command existed.
  init(raw: String) {
    switch raw {
    case "":
      self = .off

    case "read-aloud":
      self = .readAloud

    case "ask":
      self = .ask

    case "rewrite":
      self = .rewrite

    case "compose":
      self = .compose

    case "command":
      self = .command

    default:
      self = .dictate(style: raw)
    }
  }
}

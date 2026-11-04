import Foundation

// Reading a planner reply into `VoiceCommandStep`s: the JSON the instruction
// asks for, checked step by step before any of it runs.

extension VoiceCommandStep {
  /// The steps in a planner reply: a JSON object `{"steps": [...]}`, found
  /// between its first `{` and last `}` so a code fence or a stray sentence
  /// around it doesn't sink the command. Every step must parse, or none run:
  /// half a plan is a different command.
  ///
  /// `elementIDs`: the numbers the snapshot the planner saw listed. A step
  /// naming any other refuses the plan, as an unknown action does.
  static func steps(
    fromReply reply: String, maxSteps: Int, elementIDs: Set<Int> = []
  ) throws -> [VoiceCommandStep] {
    guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end,
      let plan = try? JSONDecoder().decode(Plan.self, from: Data(reply[start...end].utf8))
    else { throw VoiceCommandError.malformedReply }
    guard !plan.steps.isEmpty else { throw VoiceCommandError.notUnderstood }
    guard plan.steps.count <= maxSteps else { throw VoiceCommandError.tooManySteps }
    let steps = try plan.steps.map(Self.init(raw:))
    for id in steps.compactMap(\.elementID) where !elementIDs.contains(id) {
      throw VoiceCommandError.unknownElement(id)
    }
    return steps
  }

  private struct Plan: Decodable {
    let steps: [RawStep]
  }

  /// One step as the instruction spells it: an `action` and the one field it uses.
  private struct RawStep: Decodable {
    let action: String
    let app: String?
    let url: String?
    let keys: String?
    let text: String?
    let control: String?
    let name: String?
    /// Empty when absent, which `menuPath` refuses.
    let path: [String]
    let element: Int?
    let direction: String?
    let operation: String?
    /// A slider's or stepper's value: the model writes it as a number or a string.
    let value: String?

    private enum CodingKeys: String, CodingKey {
      case action, app, url, keys, text, control, name, path, element, direction, operation, value
    }

    /// An element number as an integer, or — the shape a model writes
    /// without the schema — a string holding one: "12", "[12]", "#12".
    private static func element(in container: KeyedDecodingContainer<CodingKeys>) -> Int? {
      if let number = try? container.decodeIfPresent(Int.self, forKey: .element) { return number }
      guard let text = try? container.decodeIfPresent(String.self, forKey: .element) else { return nil }
      return Int(text.trimmingCharacters(in: CharacterSet(charactersIn: "[]# ")))
    }

    init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      action = try container.decode(String.self, forKey: .action)
      app = try container.decodeIfPresent(String.self, forKey: .app)
      url = try container.decodeIfPresent(String.self, forKey: .url)
      keys = try container.decodeIfPresent(String.self, forKey: .keys)
      text = try container.decodeIfPresent(String.self, forKey: .text)
      control = try container.decodeIfPresent(String.self, forKey: .control)
      name = try container.decodeIfPresent(String.self, forKey: .name)
      path = try container.decodeIfPresent([String].self, forKey: .path) ?? []
      element = Self.element(in: container)
      direction = try container.decodeIfPresent(String.self, forKey: .direction)
      operation = try container.decodeIfPresent(String.self, forKey: .operation)
      value =
        (try? container.decodeIfPresent(String.self, forKey: .value))
        ?? (try? container.decodeIfPresent(Double.self, forKey: .value)).map { $0.formatted(.number.grouping(.never)) }
    }
  }

  /// The app, link and keyboard steps, then the ones aimed at what's on screen.
  private init(raw: RawStep) throws {
    switch raw.action {
    case "open_app": self = .openApp(try Self.field(raw.app))
    case "quit_app": self = .quitApp(try Self.field(raw.app))
    case "hide_app": self = .hideApp(try Self.field(raw.app))
    case "open_url": self = .openURL(try Self.url(raw.url))
    case "shortcut": self = .shortcut(try Self.chord(raw.keys))
    case "type": self = .type(try Self.typed(raw.text))
    case "media": self = .media(try Self.mediaKey(raw.control))
    default: self = try Self.screenStep(raw)
    }
  }

  private static func screenStep(_ raw: RawStep) throws -> VoiceCommandStep {
    switch raw.action {
    case "press_button": .pressButton(try field(raw.name))
    case "menu": .chooseMenuItem(try menuPath(raw.path))
    case "press": .pressElement(try element(raw.element))
    case "focus": .focusElement(try element(raw.element))
    case "select": .select(try element(raw.element))
    case "show_menu": .showMenu(try element(raw.element))
    default: try controlStep(raw)
    }
  }

  /// The steps that adjust a control, scroll, or move a window.
  private static func controlStep(_ raw: RawStep) throws -> VoiceCommandStep {
    switch raw.action {
    case "set_value": .setValue(element: try element(raw.element), value: try field(raw.value))
    case "increment": .increment(try element(raw.element))
    case "decrement": .decrement(try element(raw.element))
    case "scroll":
      .scroll(
        try ScrollDirection(rawValue: field(raw.direction)).orThrow(.malformedReply), element: raw.element)
    case "window":
      .window(try WindowOperation(rawValue: field(raw.operation)).orThrow(.unsupportedAction("window")))
    default: throw VoiceCommandError.unsupportedAction(raw.action)
    }
  }

  private static func field(_ value: String?) throws -> String {
    guard let value = value?.trimmedNonEmpty() else { throw VoiceCommandError.malformedReply }
    return value
  }

  private static func url(_ value: String?) throws -> URL {
    let spec = try field(value)
    guard let url = URL(string: spec), let scheme = url.scheme?.lowercased(), allowedSchemes.contains(scheme)
    else { throw VoiceCommandError.unsafeURL(spec) }
    return url
  }

  private static func chord(_ value: String?) throws -> KeyChord {
    let spec = try field(value)
    guard let chord = KeyChord(spec) else { throw VoiceCommandError.unknownShortcut(spec) }
    guard !DestructiveGuard.isDestructive(chord) else { throw VoiceCommandError.refused("press \(spec)") }
    return chord
  }

  /// Not trimmed: a leading space or a trailing newline may be the point.
  private static func typed(_ value: String?) throws -> String {
    guard let text = value, !text.isEmpty, text.count <= maxTypedCharacters else {
      throw VoiceCommandError.malformedReply
    }
    return text
  }

  private static func element(_ value: Int?) throws -> Int {
    guard let value else { throw VoiceCommandError.malformedReply }
    return value
  }

  private static func menuPath(_ value: [String]) throws -> [String] {
    let path = try value.map(field)
    guard (2...maxMenuDepth).contains(path.count) else { throw VoiceCommandError.malformedReply }
    return path
  }

  private static func mediaKey(_ value: String?) throws -> MediaKey {
    let name = try field(value)
    guard let key = MediaKey(rawValue: name) else { throw VoiceCommandError.unsupportedAction("media \(name)") }
    return key
  }
}

extension Optional {
  /// The value, or `error` thrown: a parse step's "this must be here".
  fileprivate func orThrow(_ error: VoiceCommandError) throws -> Wrapped {
    guard let self else { throw error }
    return self
  }
}

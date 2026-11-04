import Foundation

// Reading a planner reply into `VoiceCommandStep`s: the JSON the instruction
// asks for, checked step by step before any of it runs.

extension VoiceCommandStep {
  /// The steps in a planner reply: the JSON object `{"steps": [...]}` the
  /// schema (`VoiceCommandPlanner.responseFormat`) holds the gateway to — no
  /// fence, prose or shape around it to forgive. Every step must parse, or
  /// none run: half a plan is a different command. What's checked here is
  /// what no schema can say: a link's scheme, a chord's keys, the destructive
  /// guard, an element's number, a path's depth, a text's length.
  ///
  /// `elementIDs`: the numbers the snapshot the planner saw listed. A step
  /// naming any other refuses the plan, as an unknown action does.
  static func steps(
    fromReply reply: String, maxSteps: Int, elementIDs: Set<Int> = []
  ) throws -> [VoiceCommandStep] {
    guard let plan = try? JSONDecoder().decode(Plan.self, from: Data(reply.utf8)) else {
      throw VoiceCommandError.malformedReply
    }
    guard !plan.steps.isEmpty else { throw VoiceCommandError.notUnderstood }
    guard plan.steps.count <= maxSteps else { throw VoiceCommandError.tooManySteps }
    let steps = try plan.steps.map(Self.init(raw:))
    for id in steps.compactMap(\.elementID) where !elementIDs.contains(id) {
      throw VoiceCommandError.unknownElement(id)
    }
    return steps
  }

  /// Every field a step can carry, by its name on the wire: the keys this
  /// parser decodes and the planner's schema spells (`VoiceCommandPlanner.fields`),
  /// one list so the two can't disagree.
  enum Field: String, CodingKey, CaseIterable {
    case action, app, url, keys, text, control, name, path, element, direction, operation, value
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
    /// A slider's or stepper's value, the schema's number written as `plain`.
    let value: String?

    /// A number as `Double(_:)` reads it back: "40", "0.5" — never the
    /// user's locale's "0,5", which it can't.
    static func plain(_ number: Double) -> String {
      number == number.rounded() && abs(number) < 1e15 ? String(Int(number)) : String(number)
    }

    init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: Field.self)
      action = try container.decode(String.self, forKey: .action)
      app = try container.decodeIfPresent(String.self, forKey: .app)
      url = try container.decodeIfPresent(String.self, forKey: .url)
      keys = try container.decodeIfPresent(String.self, forKey: .keys)
      text = try container.decodeIfPresent(String.self, forKey: .text)
      control = try container.decodeIfPresent(String.self, forKey: .control)
      name = try container.decodeIfPresent(String.self, forKey: .name)
      path = try container.decodeIfPresent([String].self, forKey: .path) ?? []
      element = try container.decodeIfPresent(Int.self, forKey: .element)
      direction = try container.decodeIfPresent(String.self, forKey: .direction)
      operation = try container.decodeIfPresent(String.self, forKey: .operation)
      value = try container.decodeIfPresent(Double.self, forKey: .value).map(Self.plain)
    }
  }

  /// The app, link and keyboard steps, then the ones aimed at what's on screen.
  private init(raw: RawStep) throws {
    guard let action = Action(rawValue: raw.action) else { throw VoiceCommandError.unsupportedAction(raw.action) }
    switch action {
    case .openApp: self = .openApp(try Self.field(raw.app))
    case .quitApp: self = .quitApp(try Self.field(raw.app))
    case .hideApp: self = .hideApp(try Self.field(raw.app))
    case .openURL: self = .openURL(try Self.url(raw.url))
    case .shortcut: self = .shortcut(try Self.chord(raw.keys))
    case .type: self = .type(try Self.typed(raw.text))
    case .media: self = .media(try Self.mediaKey(raw.control))
    default: self = try Self.screenStep(action, raw)
    }
  }

  private static func screenStep(_ action: Action, _ raw: RawStep) throws -> VoiceCommandStep {
    switch action {
    case .pressButton: .pressButton(try field(raw.name))
    case .menu: .chooseMenuItem(try menuPath(raw.path))
    case .press: .pressElement(try element(raw.element))
    case .focus: .focusElement(try element(raw.element))
    case .select: .select(try element(raw.element))
    case .showMenu: .showMenu(try element(raw.element))
    default: try controlStep(action, raw)
    }
  }

  /// The steps that adjust a control, scroll, or move a window.
  private static func controlStep(_ action: Action, _ raw: RawStep) throws -> VoiceCommandStep {
    switch action {
    case .setValue: .setValue(element: try element(raw.element), value: try field(raw.value))
    case .increment: .increment(try element(raw.element))
    case .decrement: .decrement(try element(raw.element))
    case .scroll:
      .scroll(try ScrollDirection(rawValue: field(raw.direction)).orThrow(.malformedReply), element: raw.element)
    case .window:
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

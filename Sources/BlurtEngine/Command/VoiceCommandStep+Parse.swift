import Foundation

// Reading a planner reply into `VoiceCommandStep`s: the JSON the instruction
// asks for, checked step by step before any of it runs.

extension VoiceCommandStep {
  /// The steps in a planner reply: the JSON object `{"steps": [...]}` the
  /// schema (`VoiceCommandPlanner.responseFormat`) holds the gateway to — no
  /// fence, prose or shape around it to forgive. Every step must parse, or
  /// none run: half a plan is a different command. What's checked here is
  /// what no schema can say: a link's scheme, a chord's keys, the destructive
  /// guard, an element's number and kind, a path's depth, a text's length, a
  /// step looping.
  ///
  /// `listed`: the elements the snapshot the planner saw listed. A step
  /// naming any other refuses the plan, as an unknown action does; one
  /// naming an element of the wrong kind (`select` on a button) or a
  /// destructive label ("Delete") is refused before any step runs, rather
  /// than at its turn, after the steps before it have.
  static func steps(
    fromReply reply: String, maxSteps: Int, listed: [ScreenContext.Element] = []
  ) throws -> [VoiceCommandStep] {
    guard let plan = try? JSONDecoder().decode(Plan.self, from: Data(reply.utf8)) else {
      throw VoiceCommandError.malformedReply
    }
    guard !plan.steps.isEmpty else { throw VoiceCommandError.notUnderstood }
    guard plan.steps.count <= maxSteps else { throw VoiceCommandError.tooManySteps }
    var steps = try plan.steps.map(Self.init(raw:))
    // Only while the window the snapshot read is still the one in front: a
    // press may open a sheet, a shortcut a window, and a name the old window
    // listed then means a control the new one has.
    // A typed key or line break is the key wherever it falls.
    for index in steps.indices {
      let sameWindow = steps[..<index].allSatisfy { Self.keepsWindow.contains($0.action) }
      steps[index] = steps[index].canonical(among: sameWindow ? listed : [])
    }
    let elements = Dictionary(listed.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    for step in steps {
      try step.check(against: elements)
    }
    // The same step again and again is a model looping ("open_app Safari"
    // ten times over a remark, return ten times). A step that does the same
    // the second time never repeats; another can, up to five times running
    // ("click Next twice", "tab four times").
    var run = 1
    for (step, next) in zip(steps, steps.dropFirst()) {
      run = step == next ? run + 1 : 1
      if run > (Self.idempotent.contains(step.action) ? 1 : 5) {
        throw VoiceCommandError.repeatedStep(step.action.rawValue)
      }
    }
    // And a group of steps over again is a loop too: "cmd+w, cmd+q, cmd+t,
    // type mute, return" twice, planned for "mute" (2026-11-04).
    let block = Self.repeatedBlock(in: steps)
    if !block.isEmpty {
      throw VoiceCommandError.repeatedStep(block.map(\.action.rawValue).joined(separator: ", "))
    }
    return steps
  }

  /// The first group of two or more different steps followed at once by
  /// itself, else none. One step over and over ("tab four times") is a run,
  /// held to its own limit above.
  static func repeatedBlock(in steps: [VoiceCommandStep]) -> [VoiceCommandStep] {
    for length in stride(from: 2, through: steps.count / 2, by: 1) {
      for start in 0...(steps.count - 2 * length) {
        let block = steps[start..<start + length]
        guard block.contains(where: { $0 != block.first }) else { continue }
        if block.elementsEqual(steps[start + length..<start + 2 * length]) { return Array(block) }
      }
    }
    return []
  }

  /// The step as Blurt carries it out best, where the model wrote it another
  /// way: a button by name that is listed, under that name or one it
  /// starts (`NameMatch`) and as something pressable, as the listed element — read already, so not
  /// searched for again; and a type of one line break as the return key,
  /// which sends a message where a pasted line break only starts a new line.
  func canonical(among listed: [ScreenContext.Element]) -> VoiceCommandStep {
    switch self {
    case .pressButton(let name):
      // By `NameMatch`, as the search at the step's turn would match: "Marketing"
      // is the row "Marketing (has unread messages)". Only one listed under it.
      let pressable = listed.filter { Self.pressableKinds.contains($0.kind) }
      guard let match = NameMatch.best(for: name, among: pressable.map(\.label)) else { return self }
      let named = pressable.filter { $0.label == match }
      guard named.count == 1, let only = named.first else { return self }
      return .pressElement(only.id)
    case .type(let text) where ["\n", "\r\n", "\r"].contains(text):
      return .shortcut(KeyChord(modifiers: [], key: .code(KeyChord.namedKeyCodes["return"] ?? 0x24)))
    // A key's name typed as text: a model's slip for pressing it ("return"
    // pasted into Slack's quick switcher, 2026-11-04).
    case .type(let text) where Self.typedKeyNames.contains(text.lowercased()):
      return KeyChord(text.lowercased()).map(VoiceCommandStep.shortcut) ?? self
    default: return self
    }
  }

  /// The key names a `type` step means as the key: a whole step of just one.
  static let typedKeyNames: Set<String> = ["return", "enter", "tab", "escape"]

  /// The actions that do the same the second time: never planned twice running.
  static let idempotent: Set<Action> = [
    .openApp, .quitApp, .hideApp, .openURL, .window, .focus, .select, .setValue,
  ]

  /// The actions that leave the window the snapshot read in front.
  static let keepsWindow: Set<Action> = [.focus, .type, .select, .scroll, .setValue, .increment, .decrement, .media]

  /// The kinds a `press_button` may mean: anything pressable — a row by its
  /// name included — never a field or a slider.
  static let pressableKinds: Set<String> = ScreenSnapshot.kinds(
    of: [
      "AXButton", "AXLink", "AXCheckBox", "AXRadioButton", "AXMenuButton", "AXPopUpButton", "AXDisclosureTriangle",
      "AXRow", "AXMenuItem",
    ]
  ).union(["clickable"])

  /// The checks a step needs the listed elements for: the number is listed,
  /// its kind takes the action, and nothing it would press is named as
  /// destructive — a listed element's label, a button's or a menu item's name.
  private func check(against listed: [Int: ScreenContext.Element]) throws {
    switch self {
    case .pressButton(let name) where DestructiveGuard.isDestructive(label: name):
      throw VoiceCommandError.refused("press \(name)")
    case .chooseMenuItem(let path) where path.contains(where: DestructiveGuard.isDestructive(label:)):
      throw VoiceCommandError.refused("choose \(path.joined(separator: " › "))")
    default: break
    }
    guard let id = elementID else { return }
    guard let element = listed[id] else { throw VoiceCommandError.unknownElement(id) }
    if let kinds = Self.kinds[action], !kinds.contains(element.kind) {
      throw VoiceCommandError.wrongKind(action: action.rawValue, id: id, kind: element.kind)
    }
    if action == .press || action == .showMenu, DestructiveGuard.isDestructive(label: element.label) {
      throw VoiceCommandError.refused("press \(element.label)")
    }
  }

  /// The kinds of listed element each element action takes, as the snapshot
  /// names them (`ScreenSnapshot.kinds(of:)`), from the same role lists the
  /// performer checks at the step's turn. An action absent takes any kind.
  static let kinds: [Action: Set<String>] = [
    .focus: ScreenSnapshot.kinds(of: ScreenSnapshot.textEntryRoles),
    .select: ScreenSnapshot.kinds(of: ScreenSnapshot.selectableRoles),
    .setValue: ScreenSnapshot.kinds(of: ScreenSnapshot.adjustableRoles),
    .increment: ScreenSnapshot.kinds(of: ScreenSnapshot.adjustableRoles),
    .decrement: ScreenSnapshot.kinds(of: ScreenSnapshot.adjustableRoles),
  ]

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

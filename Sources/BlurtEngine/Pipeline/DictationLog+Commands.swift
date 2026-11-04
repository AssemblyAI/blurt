import Foundation

// The Control Your Mac half of the developer-mode log: every command the key
// carries out — or fails to — is appended to `commands.jsonl`, and a failure
// to `errors.jsonl` as well, beside the dictations' own, so one file holds
// everything that broke. Same enum, so it shares the gate, the serial queue,
// the encoder and `appendLine`.
//
// What's written is what a failure needs to be diagnosed from the file alone:
// what was said, which app and window, how much of the screen was listed, the
// plan step by step with each numbered element's label, and the outcome or
// the error in full. Opt-in and local like the dictation log, which already
// holds every transcript; never a field's contents, which the plan never had.
extension DictationLog {
  struct CommandEntry: Encodable {
    /// This command's id, which a later complaint about it names (`FeedbackEntry`).
    let id: String
    let ts: String
    /// What was said: the command's transcript.
    let command: String
    let app: String?
    let window: String?
    /// How many elements the planner was shown, and whether the read stopped
    /// before the window's end.
    let elements: Int
    let incomplete: Bool
    /// The plan, one readable line per step (`VoiceCommandStep.logLine`).
    let steps: [String]
    /// What actually ran, step by step: how each was carried out, how long it
    /// took, and the error that ended the command — the steps after it never ran.
    let ran: [StepRecord]
    /// What the model was sent — the user turn, the element list with it —
    /// and every reply, two when the plan was asked for again; the model, the
    /// version of the instruction and schema, and Blurt's build.
    let prompt: String?
    let replies: [String]
    let model: String?
    let promptVersion: String?
    let build: String?
    /// How it ended: "done", "pasted", "copied", or "failed".
    let outcome: String
    /// The error's stable name (`VoiceCommandError.unsafeURL`, `URLError(-1001)`)
    /// and its full text, for a command that failed.
    let errorKind: String?
    let error: String?
    /// From the command's hand-back to its end: planning plus every step.
    let milliseconds: Int
  }

  /// Where commands land, beside the dictation and error logs.
  static var defaultCommandURL: URL { HostIdentity.current.logURL("commands.jsonl") }

  /// `defaultCommandURL` as a home-abbreviated path, for the Advanced pane.
  public static var defaultCommandDisplayPath: String { displayPath(of: defaultCommandURL) }

  /// A log file's location as the Advanced pane shows it: unescaped (a space
  /// is a space, not `%20`) and the home directory as a tilde.
  static func displayPath(of url: URL) -> String {
    (url.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
  }

  /// One command as it ended: what the router knows by then.
  public struct CommandRecord: Sendable {
    public let id: String
    public let command: String
    public let context: ScreenContext
    public let steps: [VoiceCommandStep]
    /// How it ended on the pill; nil for a command a press abandoned.
    public let outcome: OverlayUIState?
    /// The error's stable name and full text, for a command that failed.
    public let failure: (kind: String, text: String)?
    public let duration: Duration
    public let ran: [StepRecord]
    public let trace: PlanTrace.Snapshot

    public init(
      id: String = UUID().uuidString, command: String, context: ScreenContext, steps: [VoiceCommandStep],
      outcome: OverlayUIState?, failure: (kind: String, text: String)?, duration: Duration, ran: [StepRecord] = [],
      trace: PlanTrace.Snapshot = .init()
    ) {
      self.id = id
      self.ran = ran
      self.trace = trace
      self.command = command
      self.context = context
      self.steps = steps
      self.outcome = outcome
      self.failure = failure
      self.duration = duration
    }
  }

  /// Appends `record`, and a failure to the error log as well. **Gated on
  /// developer mode**, like the other two logs: with the switch off this
  /// returns without touching the disk. `store` and the URLs for tests, as
  /// `append` takes them.
  public static func appendCommand(_ record: CommandRecord) {
    appendCommand(record, store: DeveloperModeStore())
  }

  static func appendCommand(
    _ record: CommandRecord, store: DeveloperModeStore, to url: URL = defaultCommandURL,
    errorsTo errorsURL: URL = defaultErrorURL
  ) {
    gated(store: store) { now in
      let entry = makeCommandEntry(record, now: now)
      appendLine(entry, to: url)
      guard let failure = record.failure else { return }
      appendLine(
        ErrorEntry(
          kind: "command.\(failure.kind)", error: failure.text, ts: entry.ts, app: record.context.appName,
          window: record.context.windowTitle, field: nil),
        to: errorsURL)
    }
  }

  static func makeCommandEntry(_ record: CommandRecord, now: Date) -> CommandEntry {
    let context = record.context
    return CommandEntry(
      id: record.id, ts: now.formatted(timestampFormat), command: record.command, app: context.appName,
      window: context.windowTitle, elements: context.elements.count, incomplete: context.incomplete,
      steps: record.steps.map { $0.logLine(in: context) }, ran: record.ran, prompt: record.trace.prompt,
      replies: record.trace.replies, model: record.trace.model, promptVersion: record.trace.promptVersion,
      build: build, outcome: outcomeName(record.outcome),
      errorKind: record.failure?.kind, error: record.failure?.text,
      milliseconds: Int(record.duration / .milliseconds(1)))
  }

  /// Blurt's version and build, from the running bundle.
  static var build: String? {
    let info = Bundle.main.infoDictionary
    guard let version = info?["CFBundleShortVersionString"] as? String else { return nil }
    return (info?["CFBundleVersion"] as? String).map { "\(version) (\($0))" } ?? version
  }

  /// A complaint about a command — "that didn't work" said to the command key
  /// (`CommandFeedback`) — logged against the command it's about, by id.
  struct FeedbackEntry: Encodable {
    let ts: String
    let feedback: String
    /// The command it's about: its id in this log, and what was said for it.
    let about: String?
    let aboutCommand: String?
  }

  /// Logs `feedback` against `about` (the last command logged, if any), in the
  /// command log and — as `command.userReported` — the error log, so a
  /// reported failure sits with every other. Gated on developer mode.
  public static func appendFeedback(_ feedback: String, about: CommandRecord?) {
    appendFeedback(feedback, about: about, store: DeveloperModeStore())
  }

  static func appendFeedback(
    _ feedback: String, about: CommandRecord?, store: DeveloperModeStore, to url: URL = defaultCommandURL,
    errorsTo errorsURL: URL = defaultErrorURL
  ) {
    gated(store: store) { now in
      let ts = now.formatted(timestampFormat)
      appendLine(FeedbackEntry(ts: ts, feedback: feedback, about: about?.id, aboutCommand: about?.command), to: url)
      appendLine(
        ErrorEntry(
          kind: "command.userReported",
          error: "Said “\(feedback)” about “\(about?.command ?? "no command")” (\(about?.id ?? "-"))", ts: ts,
          app: about?.context.appName, window: about?.context.windowTitle, field: nil),
        to: errorsURL)
    }
  }

  private static func outcomeName(_ outcome: OverlayUIState?) -> String {
    guard let outcome else { return "abandoned" }
    return switch outcome {
    case .done: "done"
    case .pasted: "pasted"
    case .noTarget: "copied"
    case .noted: "noted"
    case .idle, .connecting, .recording, .processing, .speaking, .rewriting, .commanding, .error: "failed"
    }
  }
}

extension VoiceCommandStep {
  /// The step as the command log shows it: its action and everything it names,
  /// a numbered element with the kind and label it was listed under.
  func logLine(in context: ScreenContext) -> String {
    if let line = appLine { return line }
    func element(_ id: Int) -> String {
      let listed = context.elements.first { $0.id == id }
      return "#\(id)" + (listed.map { " (\($0.kind) \"\($0.label)\")" } ?? "")
    }
    switch self {
    case .scroll(let direction, let id): return "scroll \(direction.rawValue)" + (id.map { " in \(element($0))" } ?? "")
    case .setValue(let id, let value): return "set_value \(element(id)) to \(value)"
    default: return "\(action.rawValue) \(elementID.map(element) ?? "")"
    }
  }

  /// The line for a step that names no element: an app, a link, keys, text,
  /// a button by name, a menu path, the window.
  private var appLine: String? {
    switch self {
    case .openApp(let app), .quitApp(let app), .hideApp(let app): "\(action.rawValue) \(app)"
    case .openURL(let url): "open_url \(url.absoluteString)"
    case .shortcut(let chord): "shortcut \(chord.spelled)"
    case .type(let text): "type \"\(text)\""
    case .media(let key): "media \(key.rawValue)"
    case .pressButton(let name): "press_button \"\(name)\""
    case .chooseMenuItem(let path): "menu \(path.joined(separator: " › "))"
    case .window(let operation): "window \(operation.rawValue)"
    default: nil
    }
  }
}

extension KeyChord {
  /// The chord as the planner writes it: "cmd+shift+t", "return".
  var spelled: String {
    var parts: [String] = []
    if modifiers.contains(.control) { parts.append("ctrl") }
    if modifiers.contains(.option) { parts.append("option") }
    if modifiers.contains(.shift) { parts.append("shift") }
    if modifiers.contains(.command) { parts.append("cmd") }
    switch key {
    case .character(let character): parts.append(String(character))
    case .code(let code):
      let name = Self.namedKeyCodes.first { $0.value == code && !Self.keyAliases.contains($0.key) }?.key
      parts.append(name ?? "key \(code)")
    }
    return parts.joined(separator: "+")
  }
}

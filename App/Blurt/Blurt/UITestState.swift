#if UITEST_HOOKS

  import BlurtEngine
  import Observation

  /// Shared, observable state the harness window renders and the stub injector /
  /// transcriber read. Main-actor (the app target's default isolation) because
  /// the UI and `AppCoordinator` both live there; the stubs hop onto the main
  /// actor to touch it.
  @Observable
  final class UITestState {
    static let shared = UITestState()

    /// The transcript the stub transcriber will "recognize". Bound to a text
    /// field in the harness so a test can set the expected paste payload; the
    /// default lives in the shared `UITestIdentifiers` so the suites' assertions
    /// can't drift from it.
    var cannedTranscript = UITestIdentifiers.defaultCannedTranscript

    /// What the stub injector last "pasted" — i.e. the text `DictationSession`
    /// handed to `insert`. The harness renders it so a test can read it back and
    /// confirm the transcript flowed through the whole pipeline to injection.
    private(set) var pastedText = ""

    /// The style instructions the last dictation request carried, or "—" for
    /// none: how a test sees which style a key dictated with.
    private(set) var sentStyle = "—"

    /// What the stub speaker was last asked to read ("—" before any read).
    private(set) var spokenText = "—"

    /// The voice and speed the stub speaker was last asked to use, e.g.
    /// "aai-jane @ 1.0" ("—" before any read).
    private(set) var spokenStyle = "—"

    /// The last command the stub planner was asked to plan, and each step the
    /// stub performer carried out, in order.
    var plannedCommand: String?
    var performedSteps: [String] = []

    /// The pill's last brief notice ("Your command was carried out."), kept
    /// after the pill clears it: a notice dwells under a second, shorter than
    /// XCUITest's predicate polling, so a test reads it here instead.
    var lastNotice: String?

    /// The trigger key the harness's press/release buttons drive.
    var selectedKey = TriggerKey.rightCommand

    func recordPaste(_ text: String) { pastedText = text }

    func recordStyle(_ instructions: String?) { sentStyle = instructions ?? "—" }

    func recordSpoken(_ text: String) { spokenText = text }

    func recordSpokenStyle(_ style: ReadAloudStyle) { spokenStyle = "\(style.voiceID) @ \(style.rate)" }
    func recordPlanned(_ command: String) { plannedCommand = command }
    func recordPerformed(_ step: String) { performedSteps.append(step) }

    /// Keeps `state`'s words when it's a brief notice, under the UI-test harness.
    func recordNotice(of state: OverlayUIState) {
      if UITestMode.isActive, state.noticeDwellSeconds != nil { lastNotice = state.accessibilityLabel }
    }
  }

#endif

#if os(macOS)
  import AppKit
  import ApplicationServices
  import Testing

  @testable import BlurtEngine

  /// Records the paste situations `PasteFixtureTests` replays: each app brought
  /// to the front and its focus put where a dictation would land — Google Docs'
  /// page, VS Code's editor, the Claude app's prompt box, Muse's composer, a
  /// Finder window with nothing to type in — then the paste facts read
  /// (`FocusCapture.focusFacts`, no text) and written to
  /// `Tests/PasteFixtures/pastes.json` with the outcome that's *right* there.
  /// Nothing is ever typed; only windows it opens are closed. Only on request
  /// (BLURT_RECORD_PASTE=1, BLURT_RECORD_PASTE_ONLY=a,b for some) with
  /// Accessibility trust: it drives this Mac's apps.
  @Suite(
    "Paste fixture recorder", .serialized, .tags(.drivesThisMac),
    .drivesThisMac("BLURT_RECORD_PASTE", to: "record the paste fixtures"))
  struct PasteFixtureRecorder {
    /// How a scenario's focus is reached once its app is in front.
    enum Setup {
      case none
      case keys(String)
      /// Focus the first listed element of one of `kinds` whose label starts
      /// with `label` (any label when empty).
      case focus(kinds: Set<String>, label: String)
      /// Press a listed element, then focus another.
      case pressThenFocus(press: String, kinds: Set<String>, label: String)
    }

    struct Scenario {
      let name: String
      let app: String
      let setup: Setup
      let pastes: Bool
      /// A shortcut that closes what `setup` opened.
      var teardown: String?
    }

    static let text: Set<String> = ["text area", "text field", "search field", "combo box"]

    static let scenarios: [Scenario] = [
      Scenario(
        name: "google-docs-body", app: "Google Chrome",
        setup: .pressThenFocus(press: "Blurt Docs test", kinds: text, label: "Document content"), pastes: true),
      Scenario(name: "chrome-address-bar", app: "Google Chrome", setup: .keys("cmd+l"), pastes: true),
      Scenario(name: "safari-address-bar", app: "Safari", setup: .keys("cmd+l"), pastes: true),
      Scenario(
        name: "vscode-editor", app: "Visual Studio Code", setup: .keys("cmd+n"), pastes: true, teardown: "cmd+w"),
      Scenario(
        name: "vscode-command-palette", app: "Visual Studio Code", setup: .keys("shift+cmd+p"), pastes: true,
        teardown: "escape"),
      Scenario(
        name: "claude-prompt", app: "Claude", setup: .focus(kinds: text, label: ""), pastes: true),
      Scenario(name: "slack-composer", app: "Slack", setup: .focus(kinds: text, label: "Message"), pastes: true),
      Scenario(name: "obsidian-editor", app: "Obsidian", setup: .focus(kinds: text, label: ""), pastes: true),
      // Locked, ⌘F lands in the unlock field: a secure text field in a web view.
      Scenario(name: "1password-unlock", app: "1Password", setup: .keys("cmd+f"), pastes: true),
      Scenario(name: "muse-composer", app: "Muse", setup: .none, pastes: true),
      // The composer ("Message"), not the search field above it or a message
      // bubble — unnamed text areas, whose focus lands on a content group.
      Scenario(
        name: "messages-composer", app: "Messages", setup: .focus(kinds: ["text field"], label: "Message"),
        pastes: true),
      Scenario(name: "notes-body", app: "Notes", setup: .focus(kinds: text, label: ""), pastes: true),
      Scenario(name: "textedit-document", app: "TextEdit", setup: .keys("cmd+n"), pastes: true, teardown: "cmd+w"),
      Scenario(name: "terminal-shell", app: "Terminal", setup: .keys("cmd+n"), pastes: true, teardown: "cmd+w"),
      Scenario(
        name: "system-settings-search", app: "System Settings", setup: .focus(kinds: text, label: "Search"),
        pastes: true),
      Scenario(name: "finder-window", app: "Finder", setup: .keys("cmd+n"), pastes: false, teardown: "cmd+w"),
      Scenario(name: "calculator", app: "Calculator", setup: .none, pastes: false),
    ]

    @Test("every scenario's paste facts, recorded with the outcome that's right there")
    func record() async throws {
      await MacDriver.becomeAccessory()
      let wanted = MacDriver.picks("BLURT_RECORD_PASTE_ONLY")
      var fixtures = (try? PasteFixture.loadAll()) ?? []
      let performer = SystemVoiceCommandPerformer()
      for scenario in Self.scenarios where wanted(scenario.name) {
        // One scenario's trouble (an app not installed, a field not listed)
        // skips it, never the rest; each is saved as it's recorded.
        do {
          let facts = try await Self.record(scenario, with: performer)
          fixtures.removeAll { $0.name == scenario.name }
          fixtures.append(PasteFixture(name: scenario.name, app: scenario.app, pastes: scenario.pastes, facts: facts))
          try PasteFixture.save(fixtures.sorted { $0.name < $1.name })
          print("recorded \(scenario.name): \(facts)")
        } catch {
          print("skipped \(scenario.name): \(error)")
        }
      }
    }

    static func record(_ scenario: Scenario, with performer: SystemVoiceCommandPerformer) async throws -> PasteFacts {
      try await MacDriver.bringToFront(scenario.app, with: performer)
      defer { Task { await performer.commandEnded() } }
      try await reach(scenario.setup, with: performer)
      try await Task.sleep(for: .milliseconds(700))
      let app = await KeyInjector.frontmostApp()
      guard var facts = FocusCapture.focusFacts(forRecording: true) else { throw RecordError.untrusted }
      facts.bundleID = app?.bundleIdentifier
      facts.electron = FocusCapture.isElectronApp(app)
      if let teardown = scenario.teardown { try await close(teardown, with: performer) }
      return facts
    }

    enum RecordError: Error {
      case untrusted
      case notListed(String)
    }

    static func reach(_ setup: Setup, with performer: SystemVoiceCommandPerformer) async throws {
      switch setup {
      case .none: break
      case .keys(let keys):
        guard try await MacDriver.shortcut(keys, with: performer) else { throw RecordError.notListed(keys) }
      case .focus(let kinds, let label): try await focus(kinds: kinds, label: label, with: performer)
      case .pressThenFocus(let press, let kinds, let label):
        if await MacDriver.press(labelled: press, with: performer) { try await Task.sleep(for: .seconds(1)) }
        try await focus(kinds: kinds, label: label, with: performer)
      }
    }

    static func focus(kinds: Set<String>, label: String, with performer: SystemVoiceCommandPerformer) async throws {
      guard let element = await MacDriver.first(labelled: label, kinds: kinds, with: performer) else {
        throw RecordError.notListed("no \(kinds.sorted()) labelled \(label)")
      }
      _ = try await performer.perform(.focusElement(element.id))
    }

    /// Closes what a scenario opened — never this Claude Code session's window.
    static func close(_ keys: String, with performer: SystemVoiceCommandPerformer) async throws {
      let window = await performer.screenContext().windowTitle ?? ""
      guard !window.localizedCaseInsensitiveContains("claude") else { return }
      _ = try await MacDriver.shortcut(keys, with: performer)
    }
  }
#endif

#if os(macOS)
  import AppKit
  import ApplicationServices
  import Testing

  @testable import BlurtEngine

  extension Tag {
    /// Marks suites that drive this Mac's real apps — clicking, typing keys,
    /// opening windows. Never on CI; `--filter-tag drivesThisMac` picks them.
    @Tag static var drivesThisMac: Self
  }

  extension Trait where Self == ConditionTrait {
    /// The two gates every suite that drives this Mac needs, in one place: the
    /// variable that asks for it, and Accessibility trust for the process
    /// running the tests (the terminal, or Xcode). Like `requiresLiveAudio`,
    /// a normal run reports these suites as skipped, never as a silent pass.
    static func drivesThisMac(_ variable: String, to purpose: String) -> Self {
      .enabled(
        if: ProcessInfo.processInfo.environment[variable] == "1" && AXIsProcessTrusted(),
        "set \(variable)=1 to \(purpose), with Accessibility trust for the process running the tests")
    }
  }

  /// What the suites that drive this Mac share.
  enum MacDriver {
    /// Makes the test process a registered app — an accessory, no Dock icon —
    /// the one kind that may hand the front to another app.
    static func becomeAccessory() async {
      await MainActor.run { _ = NSApplication.shared.setActivationPolicy(.accessory) }
    }

    /// Whether a name is among those a comma-separated variable picks
    /// ("Slack,Mail") — every name when it's unset.
    static func picks(_ variable: String) -> (String) -> Bool {
      guard let list = ProcessInfo.processInfo.environment[variable] else { return { _ in true } }
      let picked = Set(list.split(separator: ",").map(String.init))
      return picked.contains
    }

    /// Opens `app`, waits for it to come up, and starts a command over it so
    /// its tree is switched on (`commandStarting`). The caller ends it.
    static func bringToFront(_ app: String, with performer: SystemVoiceCommandPerformer) async throws {
      _ = try await performer.perform(.openApp(app))
      try await Task.sleep(for: .seconds(1))
      await performer.commandStarting()
    }

    /// The first element the screen read lists whose label starts with
    /// `label`, of one of `kinds` — of any kind when that's empty.
    static func first(
      labelled label: String, kinds: Set<String> = [], with performer: SystemVoiceCommandPerformer
    ) async -> ScreenContext.Element? {
      await performer.screenContext().elements.first {
        (kinds.isEmpty || kinds.contains($0.kind)) && $0.label.hasPrefix(label)
      }
    }

    /// Presses the first listed element whose label starts with `label`, if
    /// there is one, and says whether it did.
    @discardableResult
    static func press(labelled label: String, with performer: SystemVoiceCommandPerformer) async -> Bool {
      guard let element = await first(labelled: label, with: performer) else { return false }
      return (try? await performer.perform(.pressElement(element.id))) != nil
    }

    /// Presses a shortcut ("cmd+n"); false when `keys` names no chord.
    static func shortcut(_ keys: String, with performer: SystemVoiceCommandPerformer) async throws -> Bool {
      guard let chord = KeyChord(keys) else { return false }
      _ = try await performer.perform(.shortcut(chord))
      return true
    }
  }
#endif

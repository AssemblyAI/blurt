import AppKit

// The real player boundary behind `MediaPauser` — one closure per command,
// each taking the player to address, plus the cheap is-it-running read that
// gates them all. Seams-style (`DictationSession.Seams`): `var` properties
// carrying the production defaults, so tests substitute whichever they need
// (`MediaPauserTests` substitutes all four — nothing under `swift test` may
// touch a real player). Excluded from the coverage gate for the reason
// check.sh records: exercising these for real sends Apple Events into a
// running player and raises the macOS Automation prompt, neither of which CI
// has.
extension MediaPauser {
  struct Client: Sendable {
    /// Whether the player's desktop app is running — read from the process
    /// list, never from AppleScript, which would have to launch the app to
    /// answer. This read alone is not an Apple Event, so it costs nothing and
    /// prompts for nothing.
    var isRunning: @Sendable (Player) -> Bool = { player in
      !NSRunningApplication.runningApplications(withBundleIdentifier: player.bundleID).isEmpty
    }

    /// The player's `player state`, or nil when it can't be read — the app
    /// quit, the user declined the Automation prompt, a script error. Nil is
    /// "don't touch it" to the pauser.
    var playerState: @Sendable (Player) -> PlayerState? = { player in
      MediaPauser.runPlayerCommand("player state as text", player: player)
        .flatMap(PlayerState.init(rawValue:))
    }

    var pause: @Sendable (Player) -> Void = { _ = MediaPauser.runPlayerCommand("pause", player: $0) }

    var play: @Sendable (Player) -> Void = { _ = MediaPauser.runPlayerCommand("play", player: $0) }

    /// The real client — what the public initializer uses.
    static let production = Client()
  }

  /// Runs one AppleScript command against the player and returns its string
  /// result, or nil on failure. A failure — a denied Automation prompt, a
  /// script error — is a silent no-op here, never a user-facing error: the
  /// dictation itself is unaffected either way.
  ///
  /// The command rides inside its own `is running` guard: sending a command to
  /// a not-running app would *launch* it, and the player can quit between the
  /// `isRunning` read and this event (`is running` itself launches nothing).
  ///
  /// Callers reach this only from `MediaPauser`'s serial queue, so the
  /// synchronous Apple Event send — bounded only by the AE timeout against a
  /// hung player — blocks that one Dispatch thread and nothing else, and the
  /// `NSAppleScript` instance is created, used, and dropped on that one thread.
  private static func runPlayerCommand(_ command: String, player: Player) -> String? {
    let app = "application \"\(player.appName)\""
    let source = "if \(app) is running then tell \(app) to \(command)"
    guard let script = NSAppleScript(source: source) else { return nil }
    var errorInfo: NSDictionary?
    return script.executeAndReturnError(&errorInfo).stringValue
  }
}

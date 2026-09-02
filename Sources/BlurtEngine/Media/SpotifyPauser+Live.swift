import AppKit

// The real Spotify boundary behind `SpotifyPauser` — one closure per command,
// plus the cheap is-it-running read that gates them all. Seams-style
// (`DictationSession.Seams`): `var` properties carrying the production
// defaults, so tests substitute whichever they need (`SpotifyPauserTests`
// substitutes all four — nothing under `swift test` may touch the real
// Spotify). Excluded from the coverage gate for the reason check.sh records:
// exercising these for real sends Apple Events into a running Spotify and
// raises the macOS Automation prompt, neither of which CI has.
extension SpotifyPauser {
  struct Client: Sendable {
    /// Whether the Spotify desktop app is running — read from the process
    /// list, never from AppleScript, which would have to launch the app to
    /// answer. This read alone is not an Apple Event, so it costs nothing and
    /// prompts for nothing.
    var isRunning: @Sendable () -> Bool = {
      !NSRunningApplication.runningApplications(withBundleIdentifier: SpotifyPauser.spotifyBundleID)
        .isEmpty
    }

    /// Spotify's `player state`, or nil when it can't be read — Spotify quit,
    /// the user declined the Automation prompt, a script error. Nil is "don't
    /// touch it" to the pauser.
    var playerState: @Sendable () -> PlayerState? = {
      SpotifyPauser.runSpotifyCommand("player state as text")
        .flatMap(PlayerState.init(rawValue:))
    }

    var pause: @Sendable () -> Void = { _ = SpotifyPauser.runSpotifyCommand("pause") }

    var play: @Sendable () -> Void = { _ = SpotifyPauser.runSpotifyCommand("play") }

    /// The real client — what the public initializer uses.
    static let production = Client()
  }

  private static let spotifyBundleID = "com.spotify.client"

  /// Runs one AppleScript command against Spotify and returns its string
  /// result, or nil on failure. A failure — a denied Automation prompt, a
  /// script error — is a silent no-op here, never a user-facing error: the
  /// dictation itself is unaffected either way.
  ///
  /// The command rides inside its own `is running` guard: sending a command to
  /// a not-running app would *launch* it, and Spotify can quit between the
  /// `isRunning` read and this event (`is running` itself launches nothing).
  ///
  /// Callers reach this only from `SpotifyPauser`'s serial queue, so the
  /// synchronous Apple Event send — bounded only by the AE timeout against a
  /// hung Spotify — blocks that one Dispatch thread and nothing else, and the
  /// `NSAppleScript` instance is created, used, and dropped on that one thread.
  private static func runSpotifyCommand(_ command: String) -> String? {
    let source =
      "if application \"Spotify\" is running then tell application \"Spotify\" to \(command)"
    guard let script = NSAppleScript(source: source) else { return nil }
    var errorInfo: NSDictionary?
    return script.executeAndReturnError(&errorInfo).stringValue
  }
}

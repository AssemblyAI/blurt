/// A media player Blurt can pause *precisely*, because it exposes playback state
/// over its scripting interface. Listed in the order the pause is attempted.
///
/// Both entries share one vocabulary — `player state`, `pause`, `play` — so one
/// script shape covers them and only the application name differs. Each player
/// still gets **its own script**: AppleScript resolves an app's terminology when
/// the script compiles, so one script naming an app that isn't installed fails
/// whole (-2741) — a Mac without Spotify would never pause Music. The host also
/// scripts only players that are running (`running(among:)`), which spares a
/// process launch when nothing is.
/// Deliberately a closed enum rather than a configurable list: each addition needs
/// its scripting dictionary verified (Spotify's command codes are
/// `spfyPaus`/`spfyPlay`, Apple Music's `hookPaus`/`hookPlay`, both exposing
/// `player state` as `pPlS`), and each one costs the user another
/// automation-consent prompt.
///
/// ## Why browsers (YouTube) are not here, and shouldn't be added
///
/// Pausing safely requires *knowing* something is playing — otherwise "pause"
/// starts music the user never asked for. No public API answers that for a browser.
/// All three routes were measured on macOS 26 and rejected:
///
/// - **CoreAudio, device level** (`kAudioDevicePropertyDeviceIsRunningSomewhere`):
///   read `true` with the app quit and total silence. Useless.
/// - **CoreAudio, per process** (`kAudioProcessPropertyIsRunningOutput`, public
///   since macOS 14.4): enumerates processes, but reports nothing for *other*
///   processes without system-audio-recording consent — a far heavier permission
///   than the feature is worth, and worse UX than the automation prompt.
/// - **MediaRemote** (`MRMediaRemoteGetNowPlayingApplicationIsPlaying`): private,
///   and now gated — it returned `false`, and `nowPlayingInfo` nil, while Spotify
///   was demonstrably playing. Re-confirmed from a signed `.app` bundle, so
///   bundling is not the missing piece.
///
/// A blind system play/pause media key (the only thing that *reaches* a browser)
/// was therefore built as an opt-in fallback, tested in real use, and **removed**:
/// with no way to check state it toggles rather than pauses, so it started playback
/// that wasn't running. The honest routes left are a browser extension with native
/// messaging (precise, no user setup, but a product-sized lift) or
/// `execute javascript` / `do JavaScript` (precise, but each browser needs "Allow
/// JavaScript from Apple Events" enabled — verified blocked by default, Chromium
/// error 12). Don't reintroduce a blind toggle.
public enum MediaPlayerApp: String, CaseIterable, Sendable {
  /// The raw value is the name the scripting interface is addressed by — also the
  /// name macOS shows in its "Blurt wants to control …" consent prompt.
  case spotify = "Spotify"
  case appleMusic = "Music"

  /// The bundle id a running copy reports (`NSRunningApplication.bundleIdentifier`).
  public var bundleIdentifier: String {
    switch self {
    case .spotify: "com.spotify.client"
    case .appleMusic: "com.apple.Music"
    }
  }

  /// The players among `bundleIDs` (the running apps' ids), in roster order.
  public static func running(among bundleIDs: some Sequence<String?>) -> [MediaPlayerApp] {
    let ids = Set(bundleIDs.compactMap(\.self))
    return allCases.filter { ids.contains($0.bundleIdentifier) }
  }

  /// Pauses this player if it is playing, and returns `paused` when it did. The
  /// `is running` check reads the state without launching the app, which matters
  /// since it may have quit since the host looked. No `try`: a failure — `-1743`
  /// for a declined consent prompt — exits non-zero with the error on stderr, for
  /// the host to log.
  public var pauseScript: String {
    """
    if application "\(rawValue)" is running then
      tell application "\(rawValue)"
        if player state is playing then
          pause
          return "paused"
        end if
      end tell
    end if
    return ""
    """
  }

  /// Asks this player its state and nothing else: the harmless Apple Event the
  /// switch sends as it turns on, so macOS's consent prompt comes then rather
  /// than in the middle of a dictation.
  public var consentScript: String {
    """
    if application "\(rawValue)" is running then
      tell application "\(rawValue)" to get player state
    end if
    """
  }

  /// The AppleScript error number in `osascript`'s stderr — the last
  /// parenthesized number (`… Not authorized to send Apple events to Music.
  /// (-1743)`), or nil when there is none.
  public static func errorNumber(in stderr: String) -> Int? {
    var number: Int?
    var rest = Substring(stderr)
    while let open = rest.firstIndex(of: "("), let close = rest[open...].firstIndex(of: ")") {
      if let value = Int(rest[rest.index(after: open)..<close]) { number = value }
      rest = rest[rest.index(after: close)...]
    }
    return number
  }

  /// `errorNumber`'s value for a declined Automation consent: the user said no,
  /// and asking again on every dictation would only log the same refusal.
  public static let consentDeclined = -1743

  /// Resumes this player only if it is still paused: playback the user changed
  /// during the dictation — stopped it, or started it again — is theirs, and a
  /// player that quit is not relaunched.
  public var resumeScript: String {
    """
    if application "\(rawValue)" is running then
      tell application "\(rawValue)"
        if player state is paused then play
      end tell
    end if
    """
  }
}

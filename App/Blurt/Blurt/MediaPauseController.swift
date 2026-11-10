import BlurtEngine
import Foundation
import os

/// Quiets the user's music while a dictation is recording and restores it
/// afterwards, so what you're listening to doesn't end up in the microphone feed —
/// and in the transcript.
///
/// Driven from `AppCoordinator.render(_:)` on every phase, exactly like
/// `CueSoundPlayer`: the edge logic is the engine's `RecordingEdgeDetector` (shared
/// with the chimes, unit-tested there), and this type is only the AppKit-side
/// executor. Restore rides the recording→not-recording edge rather than a terminal
/// phase, so playback returns the moment the mic closes instead of a second later
/// when the paste lands.
///
/// Only the scriptable players (`MediaPlayerApp`: Spotify, Apple Music) are touched,
/// and only *precisely*: each exposes `player state`, so we pause one that is
/// already playing and resume only what we actually paused. `if application … is
/// running` is the scripting idiom that reads the running state *without* launching
/// the app, which matters — a dictation must never boot a music player. Because it
/// cannot start anything unbidden, the switch defaults on.
///
/// Browsers are deliberately out of scope; `MediaPlayerApp` documents the detection
/// routes that were measured and rejected, and the blind media-key fallback that was
/// built, tested in real use, and removed for toggling rather than pausing.
///
/// ## Why the scripts run in `/usr/bin/osascript` rather than `NSAppleScript`
///
/// This began as in-process `NSAppleScript`, and `scripts/leaks.sh` failed on it
/// twice: the leak backtraces ran through `executeAndReturnError`, so the OSA
/// machinery leaks internally per invocation. Wrapping the call in an
/// `autoreleasepool` did **not** fix it — the second failure's backtrace ran
/// straight *through* the pool — and the leak never reproduced on a dev machine,
/// only on CI, leaving no way to validate an in-process fix.
///
/// Running the script in a short-lived child makes the fix structural instead of
/// hopeful: the OSA allocations happen inside `osascript` and die with it, so no
/// Blurt frame can appear in a leak backtrace for this code. `Process` against a
/// system binary is already established here — `PermissionsReset` shells out to
/// `tccutil` the same way. TCC still attributes the Apple Event to Blurt as the
/// *responsible* process, so the consent prompt names Blurt and reads Blurt's
/// `NSAppleEventsUsageDescription` — don't remove that key.
///
/// One `osascript` per edge, not one per player: AppleScript can't take
/// app-specific terminology like `player state` through a variable application
/// reference, so both players are unrolled into a single generated script.
final class MediaPauseController {
  private nonisolated static let logger = HostIdentity.current.logger("MediaPauseController")

  /// Off-pool home for the `osascript` invocations. A Dispatch queue rather than
  /// `Task.detached`, for the same reason `DictationSession` uses one for the AX
  /// field-context read: this blocks on a child process which itself blocks on a
  /// cross-process Apple Event, so against a beachballing player it parks a thread.
  /// The Swift cooperative pool is sized to the core count and does not overcommit,
  /// so parking its threads here could stall the whole non-main runtime — including
  /// the dictation actors. Dispatch overcommits, so a blocked call costs a thread
  /// instead of the pool.
  ///
  /// **Serial**, so the restore always observes what the pause actually did. On a
  /// concurrent queue a short dictation's restore could overtake its own pause and
  /// see an empty `pausedPlayers` — leaving the music stopped, the one failure the
  /// user would actually notice.
  private static let queue = DispatchQueue(
    label: "\(HostIdentity.current.subsystem).MediaPause", qos: .userInitiated)

  /// Shared with `CueSoundPlayer`'s gate — same edges, one implementation.
  private var edges = RecordingEdgeDetector()

  /// Exactly the players *we* paused, so the restore puts back only what we took
  /// away and never starts something the user had stopped themselves.
  ///
  /// `nonisolated(unsafe)` because it is read and written only inside
  /// `Self.queue.async` blocks, and that queue is serial — so the accesses are
  /// mutually exclusive and ordered without a lock. Do not touch it from the main
  /// actor; the ordering guarantee is the whole reason it lives here.
  nonisolated(unsafe) private var pausedPlayers: [MediaPlayerApp] = []

  /// Acts on the recording edge. Call once per rendered phase.
  func transition(for phase: PipelinePhase) {
    switch edges.edge(for: phase) {
    case .began:
      // Read the settings on the main actor, at the edge, so a Settings change
      // applies to the very next dictation — the same freshness rule as the
      // press-time key-terms read.
      guard MediaPauseStore().isEnabled else { return }
      pause()
    case .ended:
      restore()
    case nil:
      break
    }
  }

  /// Enqueues the pause. Fire-and-forget: recording has already started and must
  /// never wait on another app's responsiveness, so a slow or wedged player costs
  /// at most some music bleeding into the first moments of the take.
  private func pause() {
    Self.queue.async { [self] in
      // Assigned, not appended: a stale entry from an earlier dictation whose
      // restore was skipped must not resurrect playback the user has since stopped.
      pausedPlayers = Self.pausePlayingPlayers()
    }
  }

  private func restore() {
    Self.queue.async { [self] in
      guard !pausedPlayers.isEmpty else { return }
      Self.resume(pausedPlayers)
      pausedPlayers = []
    }
  }

  /// Pauses every scriptable player that is running *and* currently playing,
  /// returning those it paused. Must be called on `queue`.
  ///
  /// Each player's block is wrapped in `try` so one uninstalled or unresponsive app
  /// can't abort the others: on a machine without Spotify, `application "Spotify"`
  /// raises rather than answering false, which would otherwise skip Apple Music too
  /// — exactly the CI configuration.
  private nonisolated static func pausePlayingPlayers() -> [MediaPlayerApp] {
    let blocks = MediaPlayerApp.allCases.map { player in
      """
      try
        if application "\(player.applicationName)" is running then
          tell application "\(player.applicationName)"
            if player state is playing then
              pause
              set out to out & "\(player.rawValue)" & linefeed
            end if
          end tell
        end if
      end try
      """
    }
    let script = "set out to \"\"\n" + blocks.joined(separator: "\n") + "\nreturn out"
    guard let output = runOSA(script) else { return [] }
    // Match back through the raw values rather than trusting order or count, so a
    // partial failure yields exactly what actually paused.
    let names = Set(output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) })
    return MediaPlayerApp.allCases.filter { names.contains($0.rawValue) }
  }

  /// Resumes the given players, each guarded by the same non-launching running
  /// check — one may have quit during the dictation, and reviving it would be
  /// absurd. Must be called on `queue`.
  private nonisolated static func resume(_ players: [MediaPlayerApp]) {
    let blocks = players.map { player in
      """
      try
        if application "\(player.applicationName)" is running then
          tell application "\(player.applicationName)" to play
        end if
      end try
      """
    }
    _ = runOSA(blocks.joined(separator: "\n"))
  }

  /// Runs `source` through `/usr/bin/osascript`, returning trimmed stdout (nil when
  /// the process couldn't launch or exited non-zero). Must be called on `queue` —
  /// see `pausedPlayers` — since it blocks until the child exits.
  ///
  /// stderr goes to a pipe rather than being inherited, so a script error (a
  /// declined automation prompt reports `-1743` here) can't spray the app's own
  /// output; and both pipes are drained *before* `waitUntilExit` so a chatty script
  /// can't deadlock against a full pipe buffer.
  private nonisolated static func runOSA(_ source: String) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", source]
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    do {
      try process.run()
    } catch {
      logger.error("osascript failed to launch: \(error.localizedDescription, privacy: .public)")
      return nil
    }
    let data = stdout.fileHandleForReading.readDataToEndOfFile()
    let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      // Logged, not surfaced: the dictation itself worked, and a modal about the
      // user's music player would be worse than silent. `-1743` here means the user
      // declined the automation prompt.
      let message =
        String(bytes: errorData, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      logger.error("osascript exited \(process.terminationStatus): \(message, privacy: .public)")
      return nil
    }
    return String(bytes: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

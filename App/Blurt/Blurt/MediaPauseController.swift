import AppKit
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
/// already playing and resume only what we paused, and only while it is still
/// paused. Only a player that is running is scripted, one script per player — see
/// `MediaPlayerApp` for why one script for both broke on a Mac without Spotify.
/// It never starts anything unbidden. Off unless its experimental switch is on
/// (`MediaPauseStore`).
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
final class MediaPauseController {
  private nonisolated static let logger = HostIdentity.current.logger("MediaPauseController")

  /// How long one `osascript` may run before it is killed. A player that answers
  /// takes milliseconds; one that is wedged must not hold the queue — and with it
  /// every later pause and resume — for as long as it stays wedged.
  private nonisolated static let timeout = DispatchTimeInterval.seconds(5)

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
  /// `nonisolated(unsafe)` because it is read and written only on `Self.queue`,
  /// and that queue is serial — so the accesses are mutually exclusive and ordered
  /// without a lock. Do not touch it from the main actor; the ordering guarantee is
  /// the whole reason it lives here.
  nonisolated(unsafe) private var pausedPlayers: [MediaPlayerApp] = []

  /// Quitting mid-dictation — a Sparkle relaunch included — must not leave the
  /// music paused, and no `.ended` edge will come.
  private var terminationObserver: NSObjectProtocol?

  init() {
    terminationObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.willTerminateNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.restoreBeforeExit() }
    }
  }

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

  /// Enqueues the pause of every running player. Fire-and-forget: recording has
  /// already started and must never wait on another app's responsiveness, so a slow
  /// or wedged player costs at most some music bleeding into the first moments of
  /// the take. The running check is `NSWorkspace`'s, on the main actor, so nothing
  /// is spawned when no player is open.
  private func pause() {
    let running = MediaPlayerApp.running(among: NSWorkspace.shared.runningApplications.map(\.bundleIdentifier))
    Self.queue.async { [self] in
      // Assigned, not appended: a stale entry from an earlier dictation whose
      // restore was skipped must not resurrect playback the user has since stopped.
      pausedPlayers = running.filter { Self.runOSA($0.pauseScript) == "paused" }
    }
  }

  private func restore() {
    Self.queue.async { [self] in resumePaused() }
  }

  /// The termination path: synchronous, so the resume lands before the process
  /// goes. Waits behind a pause still in flight, at most `timeout` per script.
  private func restoreBeforeExit() {
    Self.queue.sync { [self] in resumePaused() }
  }

  /// Resumes what the last pause took, each player in its own script so one
  /// failure can't keep the other paused. Must be called on `queue`.
  private nonisolated func resumePaused() {
    let players = pausedPlayers
    pausedPlayers = []
    for player in players { _ = Self.runOSA(player.resumeScript) }
  }

  /// Runs `source` through `/usr/bin/osascript`, returning trimmed stdout (nil when
  /// the process couldn't launch, exited non-zero, or ran past `timeout` and was
  /// killed). Must be called on `queue` — see `pausedPlayers` — since it blocks
  /// until the child exits.
  ///
  /// Both pipes are drained on their own threads while the child runs, so a chatty
  /// script can't deadlock against a full pipe buffer, and stderr goes to a pipe
  /// rather than being inherited so a script error is logged, not sprayed.
  private nonisolated static func runOSA(_ source: String) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", source]
    let stdout = PipeDrain()
    let stderr = PipeDrain()
    process.standardOutput = stdout.pipe
    process.standardError = stderr.pipe
    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }
    do {
      try process.run()
    } catch {
      logger.error("osascript failed to launch: \(error.localizedDescription, privacy: .public)")
      return nil
    }
    stdout.start()
    stderr.start()
    if exited.wait(timeout: .now() + timeout) == .timedOut {
      process.terminate()
      exited.wait()
      logger.error("osascript timed out and was killed")
      return nil
    }
    let output = stdout.finish()
    let errors = stderr.finish()
    guard process.terminationStatus == 0 else {
      // Logged, not surfaced: the dictation itself worked, and a modal about the
      // user's music player would be worse than silent. `-1743` here means the user
      // declined the automation prompt.
      logger.error("osascript exited \(process.terminationStatus): \(errors, privacy: .public)")
      return nil
    }
    return output
  }
}

/// One child pipe, read to EOF on a background thread so the child never blocks
/// on a full buffer while the caller waits for it to exit.
///
/// `@unchecked Sendable`: `text` is written once on the reading thread and read
/// only after `finish()`'s wait on `done`, which orders the two.
private nonisolated final class PipeDrain: @unchecked Sendable {
  let pipe = Pipe()
  private let done = DispatchSemaphore(value: 0)
  private var text = ""

  func start() {
    DispatchQueue.global(qos: .userInitiated).async { [self] in
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      text = String(bytes: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      done.signal()
    }
  }

  /// Everything the child wrote, trimmed. Returns once the pipe hit EOF.
  func finish() -> String {
    done.wait()
    return text
  }
}

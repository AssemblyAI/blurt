import AppKit
import BlurtEngine
import CoreServices
import Foundation
import Synchronization
import os

/// Quiets the user's music while a dictation is recording and restores it
/// afterwards, so what you're listening to doesn't end up in the microphone feed —
/// and in the transcript.
///
/// Driven from `AppCoordinator.render(_:)` on every phase, like `CueSoundPlayer`,
/// and from the selection router's `pressSettled`. The decisions are the engine's
/// `MediaPauseGate` (unit-tested there), and this type is only the AppKit-side
/// executor. A dictation's music comes back as the mic closes; an ask's waits
/// for its answer to be read, and a command's recording isn't paused at all.
///
/// Only the scriptable players (`MediaPlayerApp`: Spotify, Apple Music) are touched,
/// and only *precisely*: each exposes `player state`, so we pause one that is
/// already playing and resume only what we paused, and only while it is still
/// paused. Only a player that is running and that Blurt may already control is
/// scripted (`AutomationConsent`), one script per player — see `MediaPlayerApp`
/// for why one script for both broke on a Mac without Spotify.
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

  /// What quitting may spend resuming: per script, and in all. Enough for a
  /// resume of both players, because a pause still running when the app quits is
  /// killed (`restoreBeforeExit`) rather than waited out.
  private nonisolated static let exitScriptTimeout = DispatchTimeInterval.seconds(1)
  private static let exitBudget = DispatchTimeInterval.seconds(2)

  /// Off-pool home for the `osascript` invocations, which block on a child that
  /// blocks on another app — off the cooperative pool for `BlockingIPC`'s reasons.
  /// Not `BlockingIPC` itself, because this one must be
  /// **serial**, so the restore always observes what the pause actually did. On a
  /// concurrent queue a short dictation's restore could overtake its own pause and
  /// see an empty `pausedPlayers` — leaving the music stopped, the one failure the
  /// user would actually notice.
  private static let queue = DispatchQueue(label: HostIdentity.current.queueLabel("MediaPause"), qos: .userInitiated)

  /// The pause, resume and hold decisions (`MediaPauseGate`, unit-tested in the
  /// engine). This type only carries them out.
  private var gate = MediaPauseGate()

  /// The players *we* paused, so the restore puts back only what we took away;
  /// its still-paused check leaves alone what the user changed meanwhile.
  ///
  /// `nonisolated(unsafe)` because it is read and written only on `Self.queue`,
  /// and that queue is serial — so the accesses are mutually exclusive and ordered
  /// without a lock. Do not touch it from the main actor; the ordering guarantee is
  /// the whole reason it lives here.
  nonisolated(unsafe) private var pausedPlayers: [MediaPlayerApp] = []

  /// The pause `osascript` running now, and whether quitting has cut pauses
  /// short: the main thread kills the child the queue is waiting on.
  private nonisolated let pauseInFlight = Mutex<(process: Process?, isExiting: Bool)>((nil, false))

  /// Quitting with the music paused — mid-dictation, during an answer, a Sparkle
  /// relaunch — must not leave it paused. Kept so `deinit` can deregister it;
  /// `nonisolated(unsafe)` because the nonisolated deinit reads it, as in
  /// `OverlayWindowController` (written once in init, read once in deinit).
  private nonisolated(unsafe) var terminationObserver: (any NSObjectProtocol)?

  init() {
    terminationObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.willTerminateNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.restoreBeforeExit() }
    }
  }

  deinit {
    if let terminationObserver {
      NotificationCenter.default.removeObserver(terminationObserver)
    }
  }

  /// Acts on the edge into recording. Call once per rendered phase.
  /// `recordsCommand`: `SelectionSpeechRouter.recordsCommand`.
  func transition(for phase: PipelinePhase, recordsCommand: Bool) {
    // The switch is read at the edge, so a Settings change applies to the very
    // next dictation — the same freshness rule as the press-time key-terms read.
    perform(gate.action(for: phase, isEnabled: MediaPauseStore().isEnabled, recordsCommand: recordsCommand))
  }

  /// The selection router is at rest (`SelectionSpeechRouter.pressSettled`).
  func pressSettled() {
    perform(gate.pressSettled())
  }

  /// Fire-and-forget: recording has already started and must never wait on
  /// another app's responsiveness, so a slow or wedged player costs at most some
  /// music bleeding into the first moments of the take.
  private func perform(_ action: MediaPauseGate.Action?) {
    switch action {
    case .pause: Self.queue.async { [self] in pause() }
    case .resume: Self.queue.async { [self] in resumePaused(timeout: Self.timeout) }
    case nil: break
    }
  }

  /// Every player's Automation consent: without the prompt for Settings' note,
  /// with it as the switch turns on or its "Allow" button is clicked. A player
  /// never asked is only ever asked here, so no dictation puts the prompt up.
  /// On `BlockingIPC`, never `queue`: the prompt blocks until the user answers,
  /// and a dictation's pause and resume must not wait behind it.
  static func consent(prompting: Bool) async -> [MediaPlayerApp: AutomationConsent] {
    await BlockingIPC.run {
      Dictionary(uniqueKeysWithValues: MediaPlayerApp.allCases.map { ($0, consent(for: $0, prompting: prompting)) })
    }
  }

  /// `AEDeterminePermissionToAutomateTarget` for one player. Without the prompt
  /// it answers from TCC's records — never launching the player, and `.notRunning`
  /// when it isn't open — which is what lets a dictation check before it scripts.
  private nonisolated static func consent(for player: MediaPlayerApp, prompting: Bool) -> AutomationConsent {
    let target = NSAppleEventDescriptor(bundleIdentifier: player.bundleIdentifier)
    return withExtendedLifetime(target) {
      guard let address = target.aeDesc else { return .unknown(OSStatus(paramErr)) }
      let any = AEEventClass(typeWildCard)
      return AutomationConsent(
        status: AEDeterminePermissionToAutomateTarget(address, any, AEEventID(typeWildCard), prompting))
    }
  }

  /// Pauses every player Blurt may control and that is playing. Only a player
  /// whose consent is `.granted` is scripted: one not running isn't, and one never
  /// asked isn't either, since scripting it would put the prompt up mid-dictation.
  /// Must be called on `queue`.
  private nonisolated func pause() {
    // Kept: a resume always empties the list first, so anything left is an
    // earlier pause's, still owed — and this pause sees it as not playing.
    let earlier = pausedPlayers
    let paused = MediaPlayerApp.allCases.filter { player in
      guard !pauseInFlight.withLock({ $0.isExiting }) else { return false }
      switch Self.consent(for: player, prompting: false) {
      case .granted: break
      case .notRunning: return false
      case let consent:
        let reason = String(describing: consent)
        Self.logger.notice("not pausing \(player.rawValue, privacy: .public): \(reason, privacy: .public)")
        return false
      }
      // Only a pause that *said* it paused counts. One that timed out may have
      // found the player already paused by the user, and resuming that would
      // start music they had stopped; a player that paused and then hung staying
      // paused is the rarer, gentler failure.
      let output = Self.runOSA(player.pauseScript, timeout: Self.timeout) { process in
        pauseInFlight.withLock { state in
          if state.isExiting { process.terminate() } else { state.process = process }
        }
      }
      pauseInFlight.withLock { $0.process = nil }
      return output == "paused"
    }
    pausedPlayers = earlier + paused.filter { !earlier.contains($0) }
  }

  /// The termination path. Resumes whatever is paused — whether the gate still
  /// held the resume (a recording or an answer under way) or the resume is
  /// already queued behind a pause — and waits for it, at most `exitBudget`, so
  /// it lands before the process goes. A pause still running is killed first, and
  /// none starts after, so
  /// the wait is never spent on it. With nothing paused the queue is idle and
  /// this returns at once.
  private func restoreBeforeExit() {
    pauseInFlight.withLock { state in
      state.isExiting = true
      state.process?.terminate()
    }
    let done = DispatchSemaphore(value: 0)
    Self.queue.async { [self] in
      resumePaused(timeout: Self.exitScriptTimeout)
      done.signal()
    }
    _ = done.wait(timeout: .now() + Self.exitBudget)
  }

  /// Resumes what the last pause took, each player in its own script so one
  /// failure can't keep the other paused. Must be called on `queue`.
  private nonisolated func resumePaused(timeout: DispatchTimeInterval) {
    let players = pausedPlayers
    pausedPlayers = []
    for player in players { _ = Self.runOSA(player.resumeScript, timeout: timeout) }
  }

  /// Runs `source` through `/usr/bin/osascript`, killing it past `timeout`, and
  /// returns what it printed — or nil when it failed, timed out, or was killed.
  /// `onLaunch` gets the running child, for a caller that may kill it sooner.
  /// Must be called on `queue` — see `pausedPlayers` — since it blocks until the
  /// child exits. Every failure is logged here.
  ///
  /// Both pipes are drained on their own threads while the child runs, so a chatty
  /// script can't deadlock against a full pipe buffer, and stderr goes to a pipe
  /// rather than being inherited so a script error is logged, not sprayed.
  private nonisolated static func runOSA(
    _ source: String, timeout: DispatchTimeInterval, onLaunch: (Process) -> Void = { _ in }
  ) -> String? {
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
    onLaunch(process)
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
      // user's music player would be worse than silent.
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

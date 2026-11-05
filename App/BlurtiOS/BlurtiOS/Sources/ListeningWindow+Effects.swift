import BlurtiOSCore
import Foundation

// MARK: - Carrying out what the machine asks
//
// Each effect in order, awaited where it is work (the source opening or
// closing, the dictation ending, a resume), so the next effect — and the
// next event, since the loop is serial — finds it done. What the work
// turns out is fed back as the machine's event with the generation it was
// asked for, never acted on directly.

extension ListeningWindow {
  func run(_ effects: [Machine.Effect]) async {
    for effect in effects { await perform(effect) }
  }

  /// The work — the source, the session, the dictation — awaited; the rest at once.
  private func perform(_ effect: Machine.Effect) async {
    switch effect {
    case .activateSession: activateSession()
    case .openSource(let generation): await openSource(generation)
    case .tryResume(let generation, let mayStart): await tryResume(generation, mayStart: mayStart)
    case .endUtterance(let keepWords): await onEndingUtterance?(keepWords)
    case .closeSource(let generation): await closeSource(generation)
    case .deactivateSession(let skipIfInterrupted): deactivateSession(skipIfInterrupted: skipIfInterrupted)
    case .scheduleExpiry, .cancelExpiry, .beginBackgroundTask, .endBackgroundTask, .publish, .log: keep(effect)
    }
  }

  /// The timers, the background task, the record and the log: no work to wait on.
  private func keep(_ effect: Machine.Effect) {
    switch effect {
    case .scheduleExpiry(let date, let generation): scheduleExpiry(date, generation)
    case .cancelExpiry: cancelExpiry()
    case .beginBackgroundTask: backgroundTasks.begin(Self.interruptionTask)
    case .endBackgroundTask: backgroundTasks.end(Self.interruptionTask)
    case .publish(let record): publish(record)
    case .log(let line): Self.log.notice("\(line, privacy: .public)")
    case .activateSession, .openSource, .tryResume, .endUtterance, .closeSource, .deactivateSession: break
    }
  }

  // MARK: The audio session

  private func activateSession() {
    do {
      try audioSession.activate()
      activationFailed = false
    } catch {
      activationFailed = true
      Self.log.error("audio session activation failed: \(error.localizedDescription, privacy: .public)")
    }
  }

  /// Left active when the window was interrupted: deactivating during a call
  /// throws, and the interruption's end hands the session back anyway.
  private func deactivateSession(skipIfInterrupted: Bool) {
    if skipIfInterrupted, sessionInterrupted {
      Self.log.notice("audio session left active through the interruption")
      return
    }
    do {
      try audioSession.deactivate()
    } catch {
      Self.log.error("audio session deactivation failed: \(error.localizedDescription, privacy: .public)")
    }
  }

  // MARK: The source

  /// Opens the source under the new generation, then lets the idle mode take
  /// over. A mode that can't (no Picture in Picture here) leaves the window
  /// held, which is the base the record already says. The heartbeat runs from
  /// here until the source closes, so the lease is renewed while the window
  /// opens, waits out an interruption, or closes — a stale "ready" is the one
  /// thing it must never say, and a lapsed lease says "suspended" instead.
  private func openSource(_ generation: Machine.Generation) async {
    guard !activationFailed else {
      activationFailed = false
      feed(.openFailed(generation, .micBusy))
      return
    }
    startHeartbeat()
    do {
      try await source.open()
      feed(.opened(generation))
      await takeIdleMode()
    } catch {
      lastError = CaptureFailure.sentence(for: error)
      Self.log.error("source open failed: \(error.localizedDescription, privacy: .public)")
      feed(.openFailed(generation, CaptureFailure.reason(for: error)))
    }
  }

  private func takeIdleMode() async {
    do {
      try await idle.windowOpened(source: source)
    } catch {
      Self.log.notice("idle mode \(self.idle.kind.rawValue, privacy: .public) unavailable here; the mic stays held")
    }
  }

  /// After an interruption: the session back up, then — in front — the source
  /// started again, or — from the background, where iOS refuses a start — a
  /// wait for it to come back on its own. The idle mode takes over again
  /// after a start, so a parked mic parks again.
  private func tryResume(_ generation: Machine.Generation, mayStart: Bool) async {
    activateSession()
    if mayStart {
      do {
        try await source.hold()
      } catch {
        lastError = CaptureFailure.sentence(for: error)
        Self.log.error("resume start failed: \(error.localizedDescription, privacy: .public)")
        feed(.resumeFailed(generation, CaptureFailure.reason(for: error)))
        return
      }
    }
    let polls = Int(Self.resumePoll / Self.resumePollStep)
    for _ in 0..<polls where !source.isOpen {
      try? await clock.sleep(for: Self.resumePollStep)
    }
    guard source.isOpen else {
      Self.log.notice("resume: the source did not come back within \(Self.resumePoll, privacy: .public)")
      feed(.resumeFailed(generation, .interrupted))
      return
    }
    feed(.resumed(generation))
    if mayStart { await takeIdleMode() }
  }

  private func closeSource(_ generation: Machine.Generation) async {
    idle.windowClosing()
    stopHeartbeat()
    await source.close()
    feed(.closed(generation))
  }

  // MARK: The timers

  /// Replaces the expiry timer; a date already past fires at once.
  private func scheduleExpiry(_ date: Date, _ generation: Machine.Generation) {
    expiry?.cancel()
    let delay = date.timeIntervalSinceNow
    guard delay > 0 else {
      expiry = nil
      feed(.expired(generation))
      return
    }
    let clock = clock
    expiry = Task { [weak self] in
      try? await clock.sleep(for: .seconds(delay))
      guard !Task.isCancelled else { return }
      self?.feed(.expired(generation))
    }
  }

  private func cancelExpiry() {
    expiry?.cancel()
    expiry = nil
  }

  /// Renews the record every `SharedStore.appHeartbeatInterval` while a window
  /// exists, with `micLive` as the idle mode reads it, so the keyboard sees a
  /// lease that lapses within seconds of the app dying.
  private func startHeartbeat() {
    heartbeat?.cancel()
    let clock = clock
    heartbeat = Task { [weak self] in
      while !Task.isCancelled {
        try? await clock.sleep(for: .seconds(SharedStore.appHeartbeatInterval))
        guard !Task.isCancelled else { return }
        self?.beat()
      }
    }
  }

  private func stopHeartbeat() {
    heartbeat?.cancel()
    heartbeat = nil
  }

  // MARK: The record

  /// Writes the record for the keyboard and remembers it for the home
  /// screen. A window opening or open again is past whatever failed last.
  private func publish(_ record: ListeningState) {
    let changed = state?.window != record.window
    state = record
    if [.opening, .open].contains(record.window) { lastError = nil }
    SharedStore.publish(record)
    let fields = [
      "window": record.window.rawValue, "idle": record.idle.rawValue, "micLive": String(record.micLive),
      "seq": String(record.sequence), "reason": record.reason?.rawValue ?? "",
    ]
    DeviceTrace.record("state", fields)
    if changed { onStateChanged?(record) }
  }
}

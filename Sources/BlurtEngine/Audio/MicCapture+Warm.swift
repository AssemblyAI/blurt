import Foundation

// The warm-recorder lifecycle — build ahead of the press, validate it still
// matches the resolved input, and consume or discard — split from
// `MicCapture.swift` to stay within the lint file-length budget, like
// `MicCapture+Meter`. Members it reaches (`warm`, `logger`, `deviceSelection`,
// `makeBackend`, `resolveInput`) are internal rather than private for that
// reason: `private` is file-scoped and can't cross the split.
extension MicCapture {
  /// Pre-build a recorder so the first `start()` skips session construction.
  /// Does NOT begin capture — the device stays closed and no mic indicator
  /// shows (see `CaptureSessionRecorder`) — so a warm recorder is free to hold
  /// idle indefinitely. Safe to call multiple times; a failure here just
  /// leaves `start()` to build lazily.
  public func warmUp() {
    guard canPrepareWarmRecorder else { return }
    prepareWarmRecorder()
  }

  /// Whether it makes sense to build a warm recorder right now: nothing is
  /// capturing, nothing is mid-bring-up, and no warm recorder is already held.
  /// A scheduled re-warm that fails this has been overtaken — a press got
  /// there first — and has nothing to do.
  ///
  /// `bringingUpCapture` is the load-bearing term. Both `activeRecorder` and
  /// `warm` are nil across `start()`'s liveness wait, so testing them alone reads
  /// a live capture as "idle" and builds a recorder the press is about to race.
  var canPrepareWarmRecorder: Bool {
    activeRecorder == nil && warm == nil && !bringingUpCapture
  }

  /// The warm recorder if it is still bound to `resolved`'s input *and* was
  /// built under the same pin, else nil — discarding (and cleaning up after)
  /// one that isn't.
  ///
  /// Reuse requires *positively* confirming the device is unchanged: an
  /// unreadable route on either side leaves us unable to tell, and a recorder
  /// bound to the wrong device doesn't fail loudly — it records the wrong mic, or
  /// silence. Rebuilding is the cheaper mistake, so unknown means discard. The
  /// pin must match too, not just the device — see `WarmRecorder.pinnedUID`.
  func takeWarmRecorder(matching resolved: ResolvedInput) -> (any CaptureRecorder)? {
    guard let held = warm else { return nil }
    warm = nil
    guard held.pinnedUID == resolved.pinnedUID,
      let warmed = held.input, let input = resolved.input, warmed.deviceID == input.deviceID
    else {
      held.recorder.stopAndDiscard()
      Self.logger.info("discarded warm recorder — input device or selection changed since warm-up")
      return nil
    }
    return held.recorder
  }

  /// Queues a re-warm to run once the current actor turn finishes, so the caller
  /// (`stop()` / `cancelCapture()`) returns before the next session is built.
  ///
  /// `warmUp()` rather than a separate re-warm entry point: the two differ only
  /// in when they are called, and both answer the same question — does a warm
  /// recorder make sense right now — so they share the guard rather than each
  /// keeping a copy of it.
  func scheduleRewarm() {
    Task { [weak self] in
      await self?.warmUp()
    }
  }

  /// Builds a recorder for the current selection and records the input (and
  /// pin) it is bound to. A failure is non-fatal: `start()` then builds
  /// lazily, exactly as it would with nothing warmed.
  func prepareWarmRecorder() {
    do {
      let resolved = Self.resolveInput(selection: deviceSelection())
      warm = WarmRecorder(
        recorder: try Self.makeBackend(pinnedUID: resolved.pinnedUID),
        input: resolved.input,
        pinnedUID: resolved.pinnedUID)
      Self.logger.info("prepared a warm recorder")
    } catch {
      Self.logger.error("warm-up failed: \(error.localizedDescription, privacy: .public)")
    }
  }
}

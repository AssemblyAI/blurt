import AVFoundation
import Foundation

// The warm-recorder lifecycle — prepare ahead of the press, validate it still
// matches the live input, and let it expire — split from `MicCapture.swift` to
// stay within the lint file-length budget, like `MicCapture+Meter`. Members it
// reaches (the prepared-recorder state, `logger`, `removeFile`, `makeRecorder`)
// are internal rather than private for that reason: `private` is file-scoped and
// can't cross the split.
extension MicCapture {
  /// Pre-create and prepare a recorder so the first `start()` skips first-time
  /// hardware route discovery. Does NOT begin capture — no mic indicator. Safe to
  /// call multiple times; a failure here just leaves `start()` to prepare lazily.
  public func warmUp() {
    guard canPrepareWarmRecorder else { return }
    prepareWarmRecorder()
  }

  /// Whether it is safe to open the input for a *warm* recorder right now:
  /// nothing is capturing, nothing is mid-bring-up, and no warm recorder is
  /// already held.
  ///
  /// `bringingUpCapture` is the load-bearing term. The two recorder slots are
  /// both nil across `start()`'s liveness wait, so testing them alone reads a
  /// live capture as "idle" and prepares a second recorder onto the open input.
  var canPrepareWarmRecorder: Bool {
    activeRecorder == nil && preparedRecorder == nil && !bringingUpCapture
  }

  /// The warm recorder if it is still bound to `input`, else nil — discarding
  /// (and cleaning up after) one that isn't.
  ///
  /// Reuse requires *positively* confirming the device is unchanged: an
  /// unreadable route on either side leaves us unable to tell, and a recorder
  /// bound to the wrong device doesn't fail loudly — it records the wrong mic, or
  /// silence. Paying route activation is the cheaper mistake, so unknown means
  /// discard.
  func takeWarmRecorder(matching input: AudioRoute.InputSnapshot?) -> AVAudioRecorder? {
    preparedExpiry?.cancel()
    preparedExpiry = nil
    guard let recorder = preparedRecorder else { return nil }
    let warmed = preparedInput
    preparedRecorder = nil
    preparedInput = nil
    guard let warmed, let input, warmed.deviceID == input.deviceID else {
      Self.removeFile(at: recorder.url)
      Self.logger.info("discarded warm recorder — input device changed since warm-up")
      return nil
    }
    return recorder
  }

  /// Queues a re-warm to run once the current actor turn finishes, so the caller
  /// (`stop()` / `cancelCapture()`) returns before the input is re-opened.
  func scheduleRewarm() {
    Task { [weak self] in
      await self?.rewarm()
    }
  }

  /// Prepares the next session's recorder, unless a capture is running or coming
  /// up, or a warm one is already held — all of which mean this re-warm has been
  /// overtaken and has nothing to do.
  func rewarm() {
    guard canPrepareWarmRecorder else { return }
    prepareWarmRecorder()
  }

  /// Builds a recorder, records the input it is bound to, and starts its idle
  /// countdown. A failure is non-fatal: `start()` then prepares lazily, exactly
  /// as it did before any warm recorder existed.
  func prepareWarmRecorder() {
    do {
      let recorder = try Self.makeRecorder()
      preparedRecorder = recorder
      preparedInput = AudioRoute.currentInput()
      preparedGeneration += 1
      armPreparedRecorderExpiry(generation: preparedGeneration)
      Self.logger.info("prepared a warm recorder")
    } catch {
      Self.logger.error("warm-up failed: \(error.localizedDescription, privacy: .public)")
    }
  }

  /// Arms the idle countdown for the warm recorder identified by `generation`.
  /// The ticket is what makes a stale expiry harmless — see
  /// `releasePreparedRecorder(generation:)`.
  func armPreparedRecorderExpiry(generation: Int) {
    preparedExpiry?.cancel()
    preparedExpiry = Task { [weak self] in
      try? await Task.sleep(for: Self.preparedRecorderLifetime)
      guard !Task.isCancelled else { return }
      await self?.releasePreparedRecorder(generation: generation)
    }
  }

  /// Tears down an idle warm recorder, freeing the input device — which is what
  /// lets a Bluetooth output route return to its full-quality profile. See
  /// `preparedRecorderLifetime`.
  ///
  /// A stale expiry — one whose recorder was consumed by a press, or replaced by
  /// a later re-warm — must do nothing at all, which is what `generation` buys.
  /// Cancellation alone doesn't cover it: an expiry that already passed its
  /// `!Task.isCancelled` check still gets its actor turn, and would otherwise nil
  /// out the *live* expiry's handle (leaving the current warm recorder with no
  /// countdown at all) and tear down a recorder prepared a moment ago.
  func releasePreparedRecorder(generation: Int) {
    guard generation == preparedGeneration else { return }
    preparedExpiry = nil
    guard let recorder = preparedRecorder else { return }
    preparedRecorder = nil
    preparedInput = nil
    Self.removeFile(at: recorder.url)
    Self.logger.info("released idle warm recorder")
  }
}

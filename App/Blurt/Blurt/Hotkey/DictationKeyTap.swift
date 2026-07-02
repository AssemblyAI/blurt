import BlurtEngine
import CoreGraphics
import os

/// Drives the single lone-modifier dictation trigger from a `CGEventTap`.
///
/// Watches `flagsChanged` for the bound modifier (e.g. right ⌘, keycode 54) to
/// detect down/up, and `keyDown` for any *other* key to spot a modifier combo
/// (⌘C, ⌘V…). The per-event decision lives in the engine's `DictationKeyGate`;
/// this type only bridges `CGEvent`s to that gate and owns the tap lifecycle.
///
/// Unlike the old chord trigger, this **swallows nothing**: a lone modifier
/// types nothing into the focused app, and combos must pass through so normal
/// shortcuts keep working. The tap is therefore created `.listenOnly` — an
/// active (`.defaultTap`) tap would make macOS synchronously wait on this
/// process before delivering every keystroke system-wide, so any main-thread
/// stall in Blurt would add typing latency in *other* apps.
///
/// `@MainActor` because everything here already runs on the main thread: the
/// tap's run-loop source is added to the main run loop (`ensureRunning`), so
/// the C callback fires there, and the coordinator/UITest entry points are
/// main-actor. Isolation lets the compiler prove single-threaded access to the
/// gate state instead of guarding it with a hand-held lock.
@MainActor
final class DictationKeyTap {
  private static let logger = Logger(
    subsystem: BlurtIdentity.subsystem, category: "DictationKeyTap")

  private let onStart: @Sendable () -> Void
  private let onStop: @Sendable () -> Void
  private let onCancel: @Sendable () -> Void
  /// Fired when a *state-recovery* reset (disabled-tap recovery, trigger
  /// rebinding) discards a live gate state: the key events that would have ended
  /// that dictation can no longer arrive, so the owner must end the capture —
  /// otherwise the session sits in `.recording` until the auto-release cap
  /// pastes an unprompted transcript. Distinct from `onCancel` (a user-intent
  /// cancel from the gate): recovery must only cancel a live *recording*, never
  /// a transcript already in flight — see `DictationSession.cancelRecording`.
  private let onRecordingDiscarded: @Sendable () -> Void
  /// Fired when the undocumented Prompt Inspector chord (⌃⌥⌘P) is pressed. Opens
  /// the inspector window; the tap is listen-only so the chord also passes through
  /// to the focused app (harmless). See `InspectorHotkey`.
  private let onInspector: @MainActor () -> Void

  private var gate = DictationKeyGate()
  private var triggerKeyCode = TriggerKey.rightCommand.keyCode
  private var triggerFlag = DictationKeyTap.flag(for: .rightCommand)
  /// Tracks the bound modifier's current physical state so repeated
  /// `flagsChanged` events (from *other* modifiers changing) don't double-fire.
  private var modifierIsDown = false

  /// Monotonic reference; per-event timestamps are `reference.duration(to: now)`.
  private let reference = ContinuousClock.now

  /// `nonisolated(unsafe)` so the nonisolated `deinit` can read it: written only
  /// in `ensureRunning()` on the main actor, and the last release of an
  /// `AppCoordinator`-owned object happens on the main actor too, so the deinit
  /// read never overlaps a write.
  nonisolated(unsafe) private var tap: CFMachPort?

  init(
    onStart: @escaping @Sendable () -> Void,
    onStop: @escaping @Sendable () -> Void,
    onCancel: @escaping @Sendable () -> Void,
    onRecordingDiscarded: @escaping @Sendable () -> Void,
    onInspector: @escaping @MainActor () -> Void
  ) {
    self.onStart = onStart
    self.onStop = onStop
    self.onCancel = onCancel
    self.onRecordingDiscarded = onRecordingDiscarded
    self.onInspector = onInspector
  }

  deinit {
    // The callback holds `self` unretained (`Unmanaged.passUnretained` in
    // `userInfo`), so the tap must not outlive this object: disable it and
    // invalidate the mach port (which also tears down its run-loop source)
    // before the pointer dangles. AppCoordinator keeps the tap app-lifetime
    // today, so this is a guard against a future re-composition, not a path
    // that runs in production.
    if let tap {
      CGEvent.tapEnable(tap: tap, enable: false)
      CFMachPortInvalidate(tap)
    }
  }

  /// Idempotent. Creates and enables the tap if needed and syncs the binding.
  /// Returns false when the tap can't be created yet (process not Accessibility
  /// trusted) so the caller can retry once permissions land.
  @discardableResult
  func ensureRunning() -> Bool {
    refreshBinding()
    if let tap {
      CGEvent.tapEnable(tap: tap, enable: true)
      return true
    }
    let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
    guard
      let created = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .listenOnly,
        eventsOfInterest: CGEventMask(mask),
        callback: dictationTapCallback,
        userInfo: Unmanaged.passUnretained(self).toOpaque()
      )
    else {
      Self.logger.error("CGEvent.tapCreate failed — input not yet trusted")
      return false
    }
    tap = created
    let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
    // The main run loop, deliberately: it makes this whole class single-threaded
    // (see the @MainActor note above) — the callback below relies on it.
    CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
    CGEvent.tapEnable(tap: created, enable: true)
    Self.logger.info("dictation key tap installed")
    return true
  }

  /// Re-read the bound trigger key into the gate. Call after the user rebinds.
  /// The reset reports a discarded live recording (see `resetGate`): rebinding
  /// mid-dictation means the old key's up-event will never match, so the capture
  /// must be cancelled, not left to run out the auto-release cap.
  func refreshBinding() {
    let key = TriggerKeyStore().triggerKey
    triggerKeyCode = key.keyCode
    triggerFlag = Self.flag(for: key)
    resetGate()
  }

  /// Clears the gate (and the modifier-down tracker) because the events it was
  /// tracking can no longer be trusted — the binding changed, or the tap was
  /// disabled and events were dropped. If the reset discards a live gate state
  /// (armed or latched), no future key event can end that dictation, so report
  /// it upstream to cancel the recording.
  private func resetGate() {
    let discardedRecording = !gate.isIdle
    gate.reset()
    modifierIsDown = false
    if discardedRecording { onRecordingDiscarded() }
  }

  /// Callback entry point (always on the main thread — the tap's source lives on
  /// the main run loop). Swallows nothing: the tap is listen-only, so events are
  /// delivered regardless of what happens here.
  fileprivate func handle(type: CGEventType, event: CGEvent) {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
      // Events may have been dropped while the tap was down. If the trigger is
      // still physically held, nothing that matters was lost: the key-up is
      // still coming and the gate state is coherent, so keep both — resetting
      // here would discard speech the user is mid-sentence on. Otherwise the
      // trigger's key-up may have been missed; reset, and cancel a recording
      // the reset discards rather than leaving the session in .recording until
      // the auto-release cap fires and pastes an unprompted transcript.
      if CGEventSource.flagsState(.combinedSessionState).contains(triggerFlag) { return }
      resetGate()
      return
    }

    let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
    let eventFlags = event.flags
    // Undocumented Prompt Inspector chord. Checked here (not in the gate) so the
    // gate's dictation decision is untouched — the event still flows through it
    // normally below. Listen-only tap swallows nothing, so this never blocks the
    // keystroke reaching the focused app.
    // Ignore key autorepeat so holding the chord opens the window once, not
    // repeatedly. `.keyboardEventAutorepeat` is non-zero on synthesized repeats.
    if type == .keyDown, event.getIntegerValueField(.keyboardEventAutorepeat) == 0,
      InspectorHotkey.matches(keyCode: keyCode, flags: eventFlags.rawValue)
    {
      onInspector()
    }
    let now = reference.duration(to: ContinuousClock.now)
    dispatch(decideAction(type: type, keyCode: keyCode, eventFlags: eventFlags, now: now))
  }

  /// Feeds one event into the gate and returns its decision.
  private func decideAction(
    type: CGEventType, keyCode: Int, eventFlags: CGEventFlags, now: Duration
  ) -> DictationKeyGate.Action {
    switch type {
    case .flagsChanged:
      guard keyCode == triggerKeyCode else { return .none }
      let isDown = eventFlags.contains(triggerFlag)
      if isDown, !modifierIsDown {
        modifierIsDown = true
        return gate.modifierDown(at: now)
      }
      if !isDown, modifierIsDown {
        modifierIsDown = false
        return gate.modifierUp(at: now)
      }
      return .none
    case .keyDown:
      return keyCode == triggerKeyCode ? .none : gate.otherKeyDown()
    default:
      return .none
    }
  }

  private func dispatch(_ action: DictationKeyGate.Action) {
    switch action {
    case .start: onStart()
    case .stop: onStop()
    case .cancel: onCancel()
    case .none: break
    }
  }

  /// The `CGEventFlags` bit the bound key toggles, so a `flagsChanged` event for
  /// it reads as down (bit set) or up (bit clear). This is the *device-dependent*
  /// per-side bit (e.g. right ⌘ only), not the generic `.maskCommand` shared by
  /// both ⌘ keys — see `TriggerKey.deviceModifierMask` for why that distinction
  /// keeps the down/up tracking from desyncing on keyboards with both keys held.
  nonisolated static func flag(for key: TriggerKey) -> CGEventFlags {
    CGEventFlags(rawValue: key.deviceModifierMask)
  }

  #if UITEST_HOOKS
    /// Test seam: drive the real gate + callback dispatch for a synthetic
    /// lone-modifier press, bypassing the `CGEventTap` (whose creation needs
    /// Accessibility trust an automated run doesn't have). Pairs with
    /// `simulateReleaseForTesting()` to run the same press→hold→release path a
    /// real keypress would — used by the leak exercise (`scripts/leaks.sh`) so the
    /// DictationKeyTap → DictationKeyGate → onStart/onStop object graph is
    /// covered, not just the session the coordinator drives directly.
    func simulatePressForTesting() {
      gate.reset()
      modifierIsDown = false
      dispatch(
        decideAction(
          type: .flagsChanged, keyCode: triggerKeyCode, eventFlags: triggerFlag, now: .seconds(0)))
    }

    /// Completes the synthetic cycle as a hold (past the threshold), so the gate
    /// emits `.stop` and `onStop` fires.
    func simulateReleaseForTesting() {
      dispatch(
        decideAction(type: .flagsChanged, keyCode: triggerKeyCode, eventFlags: [], now: .seconds(2)))
    }
  #endif
}

/// Top-level (non-capturing) C callback. The tap object is passed unretained via
/// `userInfo`; AppCoordinator owns it for the app's lifetime (and `deinit`
/// invalidates the tap before the pointer could dangle). The tap is listen-only,
/// so the returned event is ignored by the system — pass it back unchanged.
private func dictationTapCallback(
  _: CGEventTapProxy,
  type: CGEventType,
  event: CGEvent,
  userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
  guard let userInfo else { return Unmanaged.passUnretained(event) }
  // Resolve the unretained pointer out here: DictationKeyTap is @MainActor and
  // therefore Sendable, so the reference crosses into the closure cleanly.
  let monitor = Unmanaged<DictationKeyTap>.fromOpaque(userInfo).takeUnretainedValue()
  // The tap's run-loop source is on the main run loop (see ensureRunning), so
  // this always fires on the main thread; assumeIsolated turns that load-bearing
  // assumption into a checked precondition instead of a silent data race. The
  // closure runs synchronously right here, so handing it the non-Sendable event
  // is safe — spelled `nonisolated(unsafe)` because region-isolation analysis
  // can't see that the call never leaves this thread.
  nonisolated(unsafe) let event = event
  MainActor.assumeIsolated {
    monitor.handle(type: type, event: event)
  }
  return Unmanaged.passUnretained(event)
}

import BlurtEngine
import CoreGraphics
import os

/// Drives the single lone-modifier dictation trigger from a `CGEventTap`.
///
/// Watches `flagsChanged` for the bound modifier (e.g. right ⌘, keycode 54) to
/// detect down/up, and `keyDown` for any *other* key to spot a modifier combo
/// (⌘C, ⌘V…). The per-event decision lives in the engine — `DictationKeyRouter`
/// (keycode relevance + down/up edge dedup) over `DictationKeyGate` (tap/hold
/// semantics) — so this type only reduces each `CGEvent` to a router event and
/// owns the tap lifecycle.
///
/// Unlike the old chord trigger, this **swallows nothing**: a lone modifier
/// types nothing into the focused app, and combos must pass through so normal
/// shortcuts keep working. The tap is therefore created `.listenOnly` — an
/// active (`.defaultTap`) tap would make macOS synchronously wait on this
/// process before delivering every keystroke system-wide, so any main-thread
/// stall in Blurt would add typing latency in *other* apps.
///
/// Main-actor (via the app target's default isolation) because everything here
/// already runs on the main thread: the tap's run-loop source is added to the
/// main run loop (`ensureRunning`), so the C callback fires there, and the
/// coordinator/UITest entry points are main-actor. Isolation lets the compiler
/// prove single-threaded access to the router state instead of guarding it with
/// a hand-held lock.
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

  /// The engine-side event router (keycode relevance, down/up edge dedup, and
  /// the gate's tap/hold state machine — all unit-tested in BlurtEngine).
  private var router = DictationKeyRouter(triggerKeyCode: TriggerKey.rightCommand.keyCode)
  /// The bound key's device-dependent `CGEventFlags` bit — the one CoreGraphics-
  /// typed piece of the binding, so it stays here rather than in the router.
  private var triggerFlag = DictationKeyTap.flag(for: .rightCommand)

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
    onRecordingDiscarded: @escaping @Sendable () -> Void
  ) {
    self.onStart = onStart
    self.onStop = onStop
    self.onCancel = onCancel
    self.onRecordingDiscarded = onRecordingDiscarded
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
    // (see the main-actor note above) — the callback below relies on it.
    CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
    CGEvent.tapEnable(tap: created, enable: true)
    Self.logger.info("dictation key tap installed")
    return true
  }

  /// Re-read the bound trigger key into the router. Call after the user
  /// rebinds. The router's reset reports a discarded live recording: rebinding
  /// mid-dictation means the old key's up-event will never match, so the capture
  /// must be cancelled, not left to run out the auto-release cap.
  func refreshBinding() {
    let key = TriggerKeyStore().triggerKey
    triggerFlag = Self.flag(for: key)
    if router.rebind(triggerKeyCode: key.keyCode) { onRecordingDiscarded() }
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
      if router.reset() { onRecordingDiscarded() }
      return
    }

    guard let routed = routerEvent(type: type, event: event) else { return }
    let now = reference.duration(to: ContinuousClock.now)
    dispatch(router.handle(routed, at: now))
  }

  /// Reduces a `CGEvent` to the router's CoreGraphics-free event shape, or nil
  /// for event types the trigger doesn't care about.
  private func routerEvent(type: CGEventType, event: CGEvent) -> DictationKeyRouter.Event? {
    let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
    switch type {
    case .flagsChanged:
      return .flagsChanged(keyCode: keyCode, triggerFlagIsOn: event.flags.contains(triggerFlag))
    case .keyDown:
      return .keyDown(keyCode: keyCode)
    default:
      return nil
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
      _ = router.reset()
      dispatch(
        router.handle(
          .flagsChanged(keyCode: router.triggerKeyCode, triggerFlagIsOn: true), at: .seconds(0)))
    }

    /// Completes the synthetic cycle as a hold (past the threshold), so the gate
    /// emits `.stop` and `onStop` fires.
    func simulateReleaseForTesting() {
      dispatch(
        router.handle(
          .flagsChanged(keyCode: router.triggerKeyCode, triggerFlagIsOn: false), at: .seconds(2)))
    }
  #endif
}

/// Top-level (non-capturing) C callback. The tap object is passed unretained via
/// `userInfo`; AppCoordinator owns it for the app's lifetime (and `deinit`
/// invalidates the tap before the pointer could dangle). The tap is listen-only,
/// so the returned event is ignored by the system — pass it back unchanged.
/// `nonisolated` opts out of the module's MainActor default: an isolated
/// function can't convert to the `CGEventTapCallBack` C function pointer — the
/// main-thread guarantee is instead asserted inside via `assumeIsolated`.
private nonisolated func dictationTapCallback(
  _: CGEventTapProxy,
  type: CGEventType,
  event: CGEvent,
  userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
  guard let userInfo else { return Unmanaged.passUnretained(event) }
  // Resolve the unretained pointer out here: DictationKeyTap is MainActor and
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

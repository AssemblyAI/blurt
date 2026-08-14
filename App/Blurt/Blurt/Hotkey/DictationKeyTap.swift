import BlurtEngine
import CoreGraphics
import os

/// Drives the single-key dictation trigger from a `CGEventTap`.
///
/// The bound trigger is a `TriggerBinding`: a lone modifier (e.g. right ⌘,
/// keycode 54) watched via `flagsChanged`, a keyboard chord (⌃⌥D) watched via
/// `keyDown`/`keyUp` plus the modifier set each event reports, or an extra mouse
/// button watched via `otherMouseDown`/`otherMouseUp`. `keyDown` is also watched
/// for any *other* key to spot a modifier combo (⌘C, ⌘V…). The per-event decision lives in the
/// engine — `DictationKeyRouter` (binding relevance + down/up edge dedup) over
/// `DictationKeyGate` (tap/hold semantics) — so this type only reduces each
/// `CGEvent` to a router event and owns the tap lifecycle. The mask covers
/// every family the router can care about regardless of the current binding
/// (a tap's mask is fixed at creation, and the router ignores irrelevant
/// events), so rebinding never has to recreate the tap.
///
/// This **swallows nothing**, by design: a lone modifier or extra mouse button
/// types and clicks nothing into the focused app, and combos must pass through
/// so normal shortcuts keep working. The tap is
/// therefore created `.listenOnly` — an active (`.defaultTap`) tap would make
/// macOS synchronously wait on this process before delivering every keystroke
/// system-wide, so any main-thread stall in Blurt would add typing latency in
/// *other* apps. Two consequences the UI states rather than hides: the Custom
/// recorder refuses a **bare** key (it would type on every dictation), and a
/// bound **chord** still reaches an app that already owns it — see
/// `TriggerBinding.passThroughNote`.
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

  /// The engine-side event router (binding relevance, down/up edge dedup, and
  /// the gate's tap/hold state machine — all unit-tested in BlurtEngine).
  /// Seeded from the persisted binding in `init` — see the note there.
  private var router: DictationKeyRouter
  /// The bound modifier's device-dependent `CGEventFlags` bit — the one
  /// CoreGraphics-typed piece of the binding, so it stays here rather than in
  /// the router. Empty for chord and mouse bindings, whose down/up state rides
  /// their own event types rather than one device bit (a chord reads the generic
  /// modifier masks, which the decoder resolves per event).
  private var triggerFlag: CGEventFlags

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
    // Both halves of the binding come from the store, not a hard-coded
    // `.rightCommand`: `TriggerBinding.fromPersisted` owns the unset default, and
    // restating it here is the same mistake `BoundTriggerBinding` and `HotkeyStepView`
    // were each corrected away from — the tap would name the old key while the
    // picker, ready screen, and menu bar all named the new one. `refreshBinding()`
    // re-reads this, but nothing enforces that it runs before the first read of
    // either property (`simulatePressForTesting` reads `router.binding`).
    let binding = TriggerKeyStore().triggerBinding
    self.router = DictationKeyRouter(binding: binding)
    self.triggerFlag = Self.flag(for: binding)
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
    let mask =
      (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
      | (1 << CGEventType.flagsChanged.rawValue)
      | (1 << CGEventType.otherMouseDown.rawValue) | (1 << CGEventType.otherMouseUp.rawValue)
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
    let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
    // The main run loop, deliberately: it makes this whole class single-threaded
    // (see the main-actor note above) — the callback below relies on it.
    CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
    CGEvent.tapEnable(tap: created, enable: true)
    Self.logger.info("dictation key tap installed")
    return true
  }

  /// Discard stale gate state after the session reached a terminal phase, so the
  /// user's next trigger press isn't swallowed.
  ///
  /// A dictation can end *without* a key event ending it: the auto-release cap
  /// fires on a long hold, or the press is refused (no API key) / fails (no input
  /// device). The gate is then left `.latched` — or `.armed`, which a quick release
  /// promotes to `.latched` — and nothing can clear it, because
  /// `DictationKeyGate.modifierDown` from `.latched` returns `.none` (so the next
  /// tap starts nothing) and the `modifierUp` after it returns `.stop`, which
  /// no-ops on an already-terminal session. The user gets one completely dead
  /// press: no pill, no chime, nothing — and if that press was a hold, a whole
  /// utterance spoken into a session that never started.
  ///
  /// Resets unconditionally, unlike the disabled-tap recovery above. That guard
  /// exists to preserve a *live* recording whose key events were dropped; here the
  /// dictation is already over, so there is no state worth keeping even if the
  /// trigger is still physically held — a later key-up just finds the router's
  /// down-tracker cleared and routes to `.none`.
  ///
  /// Acts on `reset()`'s discarded-recording result the same way `refreshBinding`
  /// does. In the stale case the session is already terminal, so the
  /// `cancelRecording` is a no-op. It matters for the one residual race: `render`
  /// consumes `phaseStream()` asynchronously, so if that loop falls behind,
  /// dictation N's terminal phase can arrive *after* the gate has armed for
  /// dictation N+1 — the reset then clears N+1's live state, its key-up routes to
  /// `.none`, and the recording would otherwise run to the ~115 s auto-release cap.
  /// Cancelling it turns a silent two-minute hang into a clean stop.
  ///
  /// A no-op in every normal flow, where the gate is already idle by the time a
  /// terminal phase lands.
  func syncAfterTerminalPhase() {
    if router.reset() { onRecordingDiscarded() }
  }

  /// Re-read the bound trigger into the router. Call after the user rebinds.
  /// The router's reset reports a discarded live recording: rebinding
  /// mid-dictation means the old trigger's up-event will never match, so the
  /// capture must be cancelled, not left to run out the auto-release cap.
  func refreshBinding() {
    let binding = TriggerKeyStore().triggerBinding
    triggerFlag = Self.flag(for: binding)
    if router.rebind(binding: binding) { onRecordingDiscarded() }
  }

  /// Callback entry point (always on the main thread — the tap's source lives on
  /// the main run loop). Swallows nothing: the tap is listen-only, so events are
  /// delivered regardless of what happens here.
  fileprivate func handle(type: CGEventType, event: CGEvent) {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
      // Events may have been dropped while the tap was down. Whether the gate's
      // state survives that is the router's call (and unit-tested there); the only
      // part that has to happen here is the CoreGraphics read of whether the
      // trigger is physically held right now.
      if router.recoverFromDroppedEvents(triggerStillHeld: triggerStillHeld()) {
        onRecordingDiscarded()
      }
      return
    }

    // The CGEvent -> router-event reduction lives in the engine
    // (`DictationEventDecoder`) so it can be exercised with real CGEvent
    // fixtures; this shim only owns the tap lifecycle around it.
    guard
      let routed = DictationEventDecoder.routerEvent(
        type: type, event: event, triggerFlag: triggerFlag)
    else { return }
    let now = reference.duration(to: ContinuousClock.now)
    dispatch(router.handle(routed, at: now))
  }

  /// The CoreGraphics read behind dropped-event recovery: is the bound trigger
  /// physically down right now? Each binding family has its own state query.
  private func triggerStillHeld() -> Bool {
    switch router.binding {
    case .modifier:
      return CGEventSource.flagsState(.combinedSessionState).contains(triggerFlag)
    case .chord(let keyCode, let modifiers):
      // Both halves have to still be down for the press to be live: the key
      // itself, and every modifier the chord requires.
      let held = DictationEventDecoder.modifiers(
        from: CGEventSource.flagsState(.combinedSessionState))
      return CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(keyCode))
        && held.isSuperset(of: modifiers)
    case .mouseButton(let button):
      // `CGMouseButton` is an open C enum, so any button number constructs; a
      // nil (out-of-range) read degrades to "not held", which resets the gate —
      // the conservative side, since keeping state with no up-event coming
      // strands the session until the auto-release cap.
      guard let cgButton = CGMouseButton(rawValue: UInt32(button)) else { return false }
      return CGEventSource.buttonState(.combinedSessionState, button: cgButton)
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

  /// The `CGEventFlags` bit a bound modifier toggles, so a `flagsChanged` event
  /// for it reads as down (bit set) or up (bit clear). This is the
  /// *device-dependent* per-side bit (e.g. right ⌘ only), not the generic
  /// `.maskCommand` shared by both ⌘ keys — see `TriggerKey.deviceModifierMask`
  /// for why that distinction keeps the down/up tracking from desyncing on
  /// keyboards with both keys held. Mouse bindings have no flag bit.
  nonisolated static func flag(for binding: TriggerBinding) -> CGEventFlags {
    guard case .modifier(let key) = binding else { return [] }
    return CGEventFlags(rawValue: key.deviceModifierMask)
  }

  #if UITEST_HOOKS
    /// Test seam: drive the real gate + callback dispatch for a synthetic
    /// trigger press, bypassing the `CGEventTap` (whose creation needs
    /// Accessibility trust an automated run doesn't have). Pairs with
    /// `simulateReleaseForTesting()` to run the same press→hold→release path a
    /// real keypress would — used by the leak exercise (`scripts/leaks.sh`) so the
    /// DictationKeyTap → DictationKeyGate → onStart/onStop object graph is
    /// covered, not just the session the coordinator drives directly.
    func simulatePressForTesting() {
      _ = router.reset()
      dispatch(router.handle(syntheticEvent(down: true), at: .seconds(0)))
    }

    /// Completes the synthetic cycle as a hold (past the threshold), so the gate
    /// emits `.stop` and `onStop` fires.
    func simulateReleaseForTesting() {
      dispatch(router.handle(syntheticEvent(down: false), at: .seconds(2)))
    }

    /// The event a real down/up of the bound trigger would reduce to, whatever
    /// family the current binding belongs to.
    private func syntheticEvent(down: Bool) -> DictationKeyRouter.Event {
      switch router.binding {
      case .modifier(let key):
        return .flagsChanged(keyCode: key.keyCode, triggerFlagIsOn: down)
      case .chord(let keyCode, let modifiers):
        return down
          ? .keyDown(keyCode: keyCode, modifiers: modifiers) : .keyUp(keyCode: keyCode)
      case .mouseButton(let button):
        return down ? .mouseDown(button: button) : .mouseUp(button: button)
      }
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

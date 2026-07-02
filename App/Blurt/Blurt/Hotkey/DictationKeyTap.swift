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
final class DictationKeyTap {
  private static let logger = Logger(
    subsystem: BlurtIdentity.subsystem, category: "DictationKeyTap")

  private let onStart: @Sendable () -> Void
  private let onStop: @Sendable () -> Void
  private let onCancel: @Sendable () -> Void

  /// Mutable state touched from the tap's run-loop thread, so guarded by a lock.
  private struct GateState {
    var gate = DictationKeyGate()
    var triggerKeyCode = TriggerKey.rightCommand.keyCode
    var triggerFlag = DictationKeyTap.flag(for: .rightCommand)
    /// Tracks the bound modifier's current physical state so repeated
    /// `flagsChanged` events (from *other* modifiers changing) don't double-fire.
    var modifierIsDown = false
  }
  private let state = OSAllocatedUnfairLock(initialState: GateState())

  /// Monotonic reference; per-event timestamps are `reference.duration(to: now)`.
  private let reference = ContinuousClock.now

  /// `nonisolated(unsafe)` so the nonisolated `deinit` and the tap-thread
  /// `handle` can read it: written once on the main actor in `ensureRunning()`
  /// (whose run loop also services the tap), read afterwards without overlap.
  nonisolated(unsafe) private var tap: CFMachPort?

  init(
    onStart: @escaping @Sendable () -> Void,
    onStop: @escaping @Sendable () -> Void,
    onCancel: @escaping @Sendable () -> Void
  ) {
    self.onStart = onStart
    self.onStop = onStop
    self.onCancel = onCancel
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
  @MainActor
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
    CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
    CGEvent.tapEnable(tap: created, enable: true)
    Self.logger.info("dictation key tap installed")
    return true
  }

  /// Re-read the bound trigger key into the gate. Call after the user rebinds.
  @MainActor
  func refreshBinding() {
    let key = TriggerKeyStore().triggerKey
    let flag = Self.flag(for: key)
    state.withLock {
      $0.triggerKeyCode = key.keyCode
      $0.triggerFlag = flag
      $0.gate.reset()
      $0.modifierIsDown = false
    }
  }

  /// Tap-thread entry point. Swallows nothing — the tap is listen-only, so
  /// events are delivered regardless of what happens here.
  fileprivate func handle(type: CGEventType, event: CGEvent) {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
      let discardedRecording = state.withLock { s in
        let wasActive = !s.gate.isIdle
        s.gate.reset()
        s.modifierIsDown = false
        return wasActive
      }
      // Events — including the trigger's key-up — were dropped while the tap
      // was disabled, so a recording that was in flight can no longer be ended
      // by the user. Cancel it rather than leaving the session in .recording
      // until the auto-release cap fires and pastes an unprompted transcript.
      if discardedRecording { onCancel() }
      return
    }

    let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
    let eventFlags = event.flags
    let now = reference.duration(to: ContinuousClock.now)
    dispatch(decideAction(type: type, keyCode: keyCode, eventFlags: eventFlags, now: now))
  }

  /// Feeds one event into the gate (under the lock) and returns its decision.
  private func decideAction(
    type: CGEventType, keyCode: Int, eventFlags: CGEventFlags, now: Duration
  ) -> DictationKeyGate.Action {
    state.withLock { s in
      switch type {
      case .flagsChanged:
        guard keyCode == s.triggerKeyCode else { return .none }
        let isDown = eventFlags.contains(s.triggerFlag)
        if isDown, !s.modifierIsDown {
          s.modifierIsDown = true
          return s.gate.modifierDown(at: now)
        }
        if !isDown, s.modifierIsDown {
          s.modifierIsDown = false
          return s.gate.modifierUp(at: now)
        }
        return .none
      case .keyDown:
        return keyCode == s.triggerKeyCode ? .none : s.gate.otherKeyDown()
      default:
        return .none
      }
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
  static func flag(for key: TriggerKey) -> CGEventFlags {
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
      let (code, flag) = state.withLock { s -> (Int, CGEventFlags) in
        s.gate.reset()
        s.modifierIsDown = false
        return (s.triggerKeyCode, s.triggerFlag)
      }
      dispatch(decideAction(type: .flagsChanged, keyCode: code, eventFlags: flag, now: .seconds(0)))
    }

    /// Completes the synthetic cycle as a hold (past the threshold), so the gate
    /// emits `.stop` and `onStop` fires.
    func simulateReleaseForTesting() {
      let code = state.withLock { $0.triggerKeyCode }
      dispatch(decideAction(type: .flagsChanged, keyCode: code, eventFlags: [], now: .seconds(2)))
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
  let monitor = Unmanaged<DictationKeyTap>.fromOpaque(userInfo).takeUnretainedValue()
  monitor.handle(type: type, event: event)
  return Unmanaged.passUnretained(event)
}

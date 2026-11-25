import BlurtEngine

// The trigger key's upkeep outside the dictation path itself: retrying a key
// tap that failed to install, and keeping macOS's own 🌐 action out of `fn`'s way.
extension AppCoordinator {
  /// Re-attempts the key tap install after a failed `ensureRunning()`.
  /// `showOverlay()` runs once, on the not-ready→ready transition; if
  /// `CGEvent.tapCreate` fails at that moment (a fresh Accessibility grant can
  /// lag behind `AXIsProcessTrusted()` flipping true), nothing else would try
  /// again — `isReady` stays true, so the transition never re-fires and the
  /// hotkey stayed dead until relaunch. The wizard's lifetime permission poll
  /// calls this on each tick while the app is ready, so the install keeps being
  /// retried until it lands. No-op once the tap exists.
  func retryKeyTapInstallIfNeeded() {
    guard let keyTap, !keyTap.isInstalled else {
      return
    }
    keyTap.ensureRunning()
  }

  /// Turns macOS's own 🌐 action off while `fn` is a trigger, and back on
  /// otherwise (see `GlobeKeyOverride`). Also run from `start()`, so the relaunch
  /// after a settings reset restores the user's setting.
  func syncGlobeKeyOverride() {
    #if UITEST_HOOKS
      // UI tests set fn to every action; the 🌐 setting it writes is the Mac's
      // own, one per login, and no test may change it.
      if UITestMode.isActive {
        return
      }
    #endif
    GlobeKeyOverride().sync(boundKeys: TriggerKeyBindings().enabledKeys)
  }
}

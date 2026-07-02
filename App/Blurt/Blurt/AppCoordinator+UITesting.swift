#if UITEST_HOOKS
  // MARK: - UI-test dictation drivers
  //
  // XCUITest can't synthesize the lone right-modifier `flagsChanged` event the
  // real trigger relies on — and the `CGEventTap` that reads it needs the
  // process to be Accessibility-trusted, which the CI test host isn't. The test
  // harness window instead calls `beginDictation`/`endDictation`/
  // `cancelDictation`, which drive the *same* `DictationSession` (and its
  // press-time missing-key readiness check) the key tap's closures reach via
  // `session.submit(_:)`. Compiled only in Debug, so nothing here ships in the
  // notarized Release build.
  extension AppCoordinator {
    /// Fire a synthetic dictation-key press/release through the *real* key tap
    /// (gate + callbacks), not the session directly. Lets the leak exercise
    /// (`scripts/leaks.sh`) cover the DictationKeyTap object graph a real
    /// keypress would build. No-ops if the tap wasn't created.
    func simulateDictationPressForTesting() { keyTap?.simulatePressForTesting() }
    func simulateDictationReleaseForTesting() { keyTap?.simulateReleaseForTesting() }
  }
#endif

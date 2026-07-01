#if UITEST_HOOKS
  // MARK: - UI-test dictation drivers
  //
  // XCUITest can't synthesize the lone right-modifier `flagsChanged` event the
  // real trigger relies on — and the `CGEventTap` that reads it needs the
  // process to be Accessibility-trusted, which the CI test host isn't. These
  // mirror the key tap's `onStart`/`onStop`/`onCancel` closures so a UI test
  // drives the *same* pipeline (`DictationSession`) the hotkey would, just via
  // the test harness window instead of a key event. Compiled only in Debug, so
  // they never ship in the notarized Release build.
  extension AppCoordinator {
    /// Mirrors the key tap's `onStart`: honors the missing-key gate (so the
    /// no-key path is testable), otherwise begins recording.
    func uiTestBeginDictation() async {
      guard hasAPIKey else {
        onMissingAPIKey()
        return
      }
      await session.press()
    }

    /// Mirrors the key tap's `onStop` — stop recording and run transcribe→inject.
    func uiTestEndDictation() async {
      await session.release()
    }

    /// Mirrors the key tap's `onCancel` — abandon the in-flight dictation.
    func uiTestCancelDictation() async {
      await session.cancel()
    }

    /// Fire a synthetic dictation-key press/release through the *real* key tap
    /// (gate + callbacks), not the session directly. Lets the leak exercise
    /// (`scripts/leaks.sh`) cover the DictationKeyTap object graph a real
    /// keypress would build. No-ops if the tap wasn't created.
    func simulateDictationPressForTesting() { keyTap?.simulatePressForTesting() }
    func simulateDictationReleaseForTesting() { keyTap?.simulateReleaseForTesting() }
  }
#endif

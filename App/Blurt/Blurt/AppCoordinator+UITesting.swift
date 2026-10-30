#if UITEST_HOOKS
  import BlurtEngine

  // MARK: - UI-test dictation drivers
  //
  // XCUITest can't synthesize the lone-modifier `flagsChanged` event the real
  // triggers rely on — and the `CGEventTap` that reads it needs the process to
  // be Accessibility-trusted, which the CI test host isn't. The test harness
  // window drives the *real* key tap's gate and callbacks instead, for any
  // trigger key, so the whole path — the tap, the read-aloud router, the
  // session — runs as a keypress would. Compiled only in Debug, so nothing here
  // ships in the notarized Release build.
  extension AppCoordinator {
    /// Fire a synthetic press/release of `key` (the bound key unless given)
    /// through the real key tap. No-ops if the tap wasn't created.
    func simulateKeyPressForTesting(_ key: TriggerKey? = nil) { keyTap?.simulatePressForTesting(key) }
    func simulateKeyReleaseForTesting(_ key: TriggerKey? = nil, asTap: Bool = false) {
      keyTap?.simulateReleaseForTesting(key, asTap: asTap)
    }

    /// Sets how `key` is pressed, as the Keys tab would, and rebinds the tap.
    func setKeyActivationForTesting(_ activation: TriggerActivation, for key: TriggerKey) {
      TriggerKeyActivationStore().setActivation(activation, for: key)
      dictationBindingChanged()
    }

    /// Sets what `key` does, as the Keys tab would, and rebinds the tap.
    func setKeyChoiceForTesting(_ choice: TriggerKeyChoice, for key: TriggerKey) {
      TriggerKeyStyleStore().setChoice(choice, for: key)
      dictationBindingChanged()
    }
  }
#endif

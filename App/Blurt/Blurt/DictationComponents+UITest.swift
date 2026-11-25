#if UITEST_HOOKS

  extension DictationComponents {
    /// The all-stub pipeline used under UI testing: no mic, no network, no
    /// Accessibility paste. `UITestMic` inherits `MicCaptureProtocol`'s default
    /// empty `levels` stream (the overlay meter isn't asserted), no-op
    /// `warmUp()`, and stop-and-discard `cancelCapture()`.
    static func uiTest() -> DictationComponents {
      DictationComponents(
        mic: UITestMic(),
        transcriber: UITestTranscriber(),
        injector: UITestInjector()
      )
    }
  }

#endif

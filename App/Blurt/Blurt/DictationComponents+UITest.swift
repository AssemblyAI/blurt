#if UITEST_HOOKS

  extension DictationComponents {
    /// The all-stub pipeline used under UI testing: no mic, no network, no
    /// Accessibility paste. `UITestMic`'s `levels` stream is empty (the overlay
    /// meter isn't asserted).
    static func uiTest() -> DictationComponents {
      DictationComponents(
        mic: UITestMic(),
        transcriber: UITestTranscriber(),
        injector: UITestInjector()
      )
    }
  }

#endif

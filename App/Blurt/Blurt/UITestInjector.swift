#if UITEST_HOOKS

  import BlurtEngine

  /// Stub injector: records what would have been pasted into the focused app
  /// rather than posting a Cmd-V `CGEvent` (which needs Accessibility and a real
  /// target app). The harness window plays the role of "the app being pasted
  /// into", surfacing the recorded text for the test to assert on.
  nonisolated struct UITestInjector: InjectorProtocol {
    func setTarget(_: CapturedFocus?) {
      // Nothing to aim at: the stub pastes into the harness, not a focused app.
    }
    func insert(_ text: String, after _: String?, windowTitle _: String?, secure _: Bool) async {
      await MainActor.run { UITestState.shared.recordPaste(text) }
    }
  }

#endif

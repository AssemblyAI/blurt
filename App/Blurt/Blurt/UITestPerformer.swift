#if UITEST_HOOKS
  import BlurtEngine

  /// Stub performer: records each step it's handed instead of carrying it out
  /// (no Accessibility, no app opened), over a fixed small screen.
  nonisolated struct UITestPerformer: VoiceCommandPerforming {
    func screenContext() -> ScreenContext {
      ScreenContext(
        appName: "Notes", windowTitle: "Shopping", elements: [.init(id: 1, kind: "button", label: "New Note")]
      )
    }

    func perform(_ step: VoiceCommandStep) async -> String? {
      await MainActor.run { UITestState.shared.recordPerformed(String(describing: step)) }
      return "stubbed"
    }
  }
#endif

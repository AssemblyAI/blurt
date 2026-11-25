#if UITEST_HOOKS

  import BlurtEngine

  /// Stub read-aloud speaker: records what it's asked to read, then "plays"
  /// until stopped (or a while passes), so a test can watch a read start, run
  /// and be interrupted — no network, no audio.
  nonisolated struct UITestReadAloudSpeaker: ReadAloudSpeaker {
    func speak(_ text: String, style: ReadAloudStyle, onLevel _: (@Sendable (Float) -> Void)?) async throws {
      await MainActor.run {
        UITestState.shared.recordSpoken(text)
        UITestState.shared.recordSpokenStyle(style)
      }
      try await Task.sleep(for: .seconds(20))
    }

    func answer(
      _ request: String, about _: String, style _: ReadAloudStyle, onLevel _: (@Sendable (Float) -> Void)?
    ) async throws {
      await MainActor.run { UITestState.shared.recordSpoken("Answer to: \(request)") }
      try await Task.sleep(for: .seconds(20))
    }
  }

#endif

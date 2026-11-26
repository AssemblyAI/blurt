#if UITEST_HOOKS

  import BlurtEngine
  import Foundation

  /// Stub transcriber: returns the harness's canned transcript, so the "spoken"
  /// text is whatever the test set — no network, fully deterministic.
  nonisolated struct UITestTranscriber: TranscriberProtocol {
    func transcribe(
      frames: AsyncStream<Data>, sampleRate _: Int, context: TranscriptionContext?
    ) async -> String {
      // The feed still has to be drained: the session hands over a live feed at
      // press, and the release cannot complete until someone consumes it. The
      // context needs no draining now — the streaming route settles it before
      // the request opens, so it arrives as a value.
      for await _ in frames {
        // Discarded: the stub only has to consume the feed, not hear it.
      }
      return await MainActor.run {
        UITestState.shared.recordStyle(context?.styleInstructions)
        return UITestState.shared.cannedTranscript
      }
    }

    func warmUp() {
      // No connection to pre-open: the stub never reaches a network.
    }

    /// No prompt: the stub sends nothing.
    func contextPrompt(for _: TranscriptionContext?) -> String { "" }
  }

#endif

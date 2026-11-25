import Foundation
import os

#if os(macOS)

  // A voice sample from Settings, and a read or answer as the router's speech task: its start, meter and end on
  // the pill, guarded by generation so a stopped read's late end can't touch a
  // newer one's.
  extension SelectionSpeechRouter {
    /// Speaks a short sample in the chosen voice at the chosen speed, as picking
    /// a cue sound plays it. A newer pick cuts off the one still playing.
    public func previewSample() {
      let style = ReadAloudStyleStore(defaults: defaults).style
      let name = speaker.voice(for: style.voiceID)?.name ?? "your voice"
      let sample = style.verbatim
      preview?.cancel()
      preview = Task { [weak self, speaker] in
        do {
          let line = "Hi, I'm \(name). This is how Blurt reads your selection."
          try await speaker.speak(line, style: sample, onLevel: nil)
        } catch is CancellationError {
          // A newer pick cut it off: nothing to report.
        } catch {
          Self.logger.error("voice preview failed: \(error.localizedDescription, privacy: .public)")
          self?.speechFailed(error)
        }
      }
    }

    /// Reports the read the pill is showing as over, once: the meter to 0, then
    /// `speechEnded`.
    func endSpeech() {
      guard activeGeneration != nil else {
        return
      }
      activeGeneration = nil
      speechLevel(0)
      speechEnded()
    }

    /// Runs one read or answer as the current speech task, handing it the meter
    /// callback, and reports its start and end. `startCueDelay` holds back the
    /// start (the pill and its chime) — skipped if the speech has already
    /// ended by then.
    func run(
      startCueDelay: Duration = .zero,
      _ work: @escaping @Sendable (_ onLevel: @escaping @Sendable (Float) -> Void) async throws -> Void
    ) {
      speechGeneration += 1
      let generation = speechGeneration
      activeGeneration = generation
      if startCueDelay == .zero {
        speechStarted()
      } else {
        Task { [weak self, clock] in
          try? await clock.sleep(for: startCueDelay)
          guard let self, activeGeneration == generation else {
            return
          }
          speechStarted()
        }
      }
      let onLevel: @Sendable (Float) -> Void = { [weak self] level in
        Task { @MainActor in
          guard let self, self.activeGeneration == generation else {
            return
          }
          self.speechLevel(level)
        }
      }
      speech = Task { [weak self] in
        do {
          try await work(onLevel)
        } catch is CancellationError {
          // Stopped, not failed: nothing to report.
        } catch {
          Self.logger.error("read-aloud failed: \(error.localizedDescription, privacy: .public)")
          self?.speechFailed(error)
        }
        if let self, activeGeneration == generation { endSpeech() }
        // A read this router stopped was cancelled, and a newer one may already
        // be playing, so only a read that ended on its own reports back.
        guard !Task.isCancelled, let self else {
          return
        }
        speech = nil
        perform(routing.speechFinished())
      }
    }
  }
#endif

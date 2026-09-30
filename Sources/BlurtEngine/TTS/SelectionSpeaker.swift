/// Reads text aloud with AssemblyAI's streaming TTS. This is the engine half of
/// the experimental read-selection-aloud press (`SelectionSpeechStore`); the app
/// decides when to call it.
///
/// `speak` runs until the last sample has played. To stop early, cancel the task
/// that is awaiting it: cancellation silences playback at once and closes the
/// socket.
public struct SelectionSpeaker: Sendable {
  /// The most text one press will read. Enough for several paragraphs, while
  /// keeping a whole-document select-all from queueing minutes of audio (and
  /// the TTS usage that comes with it) behind a single tap.
  public static let maxCharacters = 4_000

  private let synthesizer: AssemblyAISpeechSynthesizer
  private let makeSink: @Sendable () -> any PCMSink

  public init() {
    self.init(synthesizer: AssemblyAISpeechSynthesizer()) {
      StreamingPCMPlayer(sampleRate: AssemblyAISpeechSynthesizer.sampleRate)
    }
  }

  /// `makeSink` is the playback seam. There is one sink per `speak`, so a
  /// cancelled read can't bleed into the next one.
  init(synthesizer: AssemblyAISpeechSynthesizer, makeSink: @escaping @Sendable () -> any PCMSink) {
    self.synthesizer = synthesizer
    self.makeSink = makeSink
  }

  /// The focused field's selected text, or nil when there is none, when the
  /// field is secure, or when it can't be read.
  ///
  /// The read is synchronous cross-process Accessibility IPC that can block a
  /// thread for the AX timeout against a hung app. So it runs on
  /// `DictationSession.contextQueue`, the press-time capture's queue, and never
  /// on the cooperative pool. That queue's doc explains why.
  public static func focusedSelection() async -> String? {
    await withCheckedContinuation { continuation in
      DictationSession.contextQueue.async {
        continuation.resume(returning: FocusCapture.captureSelectedText(maxChars: maxCharacters))
      }
    }
  }

  public func speak(_ text: String) async throws {
    let player = makeSink()
    try await withTaskCancellationHandler {
      do {
        for try await chunk in synthesizer.synthesize(text) {
          player.enqueue(chunk)
        }
      } catch {
        player.stop()
        throw error
      }
      await player.drain()
    } onCancel: {
      player.stop()
    }
  }
}

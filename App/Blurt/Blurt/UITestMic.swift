#if UITEST_HOOKS

  import BlurtEngine
  import Foundation

  // The three pipeline doubles (`UITestMic`, `UITestTranscriber`,
  // `UITestInjector`) are `nonisolated`, opting out of the app target's
  // MainActor default: they witness the engine's nonisolated protocol seams and
  // must keep running wherever the session calls them (hopping every stub call
  // through the main actor would serialize the pipeline behind the UI).

  /// Stub mic: captures nothing, returns a fixed blob comfortably above
  /// `RecordingLimits.minPCMBytes` so the pipeline clears the too-short-audio
  /// guard and proceeds to transcribe.
  nonisolated struct UITestMic: MicCaptureProtocol {
    private static let cannedPCM = Data(count: RecordingLimits.minPCMBytes * 2)

    /// Hands the chunked upload the same blob `stop()` reports, as one frame, so
    /// the streamed request carries what the release path counts.
    func start() -> AsyncStream<Data> {
      AsyncStream { continuation in
        continuation.yield(Self.cannedPCM)
        continuation.finish()
      }
    }
    func stop() -> Int {
      Self.cannedPCM.count
    }
  }

#endif

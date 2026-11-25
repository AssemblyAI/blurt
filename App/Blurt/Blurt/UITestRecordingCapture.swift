#if UITEST_HOOKS

  import BlurtEngine
  import Foundation

  /// The Record button's capture double: the test host has neither the
  /// microphone nor the System Audio Recording grant the real recorder needs.
  /// It writes a stand-in file where the recording goes — the canned
  /// transport behind the diarized pass never reads it — and hands the feed
  /// one 100 ms slice of silence from another queue, as the real recorder
  /// hands its slices from the audio thread, so the recording's send pump
  /// runs.
  nonisolated final class UITestRecordingCapture: RecordingCapture {
    /// 100 ms of 16 kHz mono S16LE.
    private static let silence = Data(count: 3_200)

    func start(to url: URL, onPCM: @escaping @Sendable (Data) -> Void) throws {
      try Data("uitest".utf8).write(to: url)
      DispatchQueue.global().async { onPCM(Self.silence) }
    }

    func pause() {
      // Nothing more is captured, so there is nothing to hold.
    }

    func resume() {
      // As `pause`: nothing to carry on with.
    }

    func stop() {
      // The stand-in file is already whole.
    }
  }

#endif

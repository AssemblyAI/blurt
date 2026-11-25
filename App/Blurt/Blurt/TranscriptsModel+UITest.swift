#if UITEST_HOOKS

  import AssemblyAI
  import BlurtEngine
  import Foundation
  import Synchronization

  extension TranscriptsModel {
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

    /// The Record button's live-session double: it opens no socket, and holds
    /// a script of turns it releases one per `next()` — the harness's Next
    /// Turn — so a test reads each partial and final as it lands rather than
    /// racing a timer; `fail()` ends it as a dropped connection would. Audio
    /// sent to it goes nowhere.
    actor UITestLiveSession: LiveTranscriptionSession {
      /// The session the newest recording opened, for the harness to drive.
      /// Locked rather than main-actor: the model's session factory is
      /// `@Sendable`, so it registers each session from no particular actor.
      nonisolated private static let current = Mutex<UITestLiveSession?>(nil)

      /// Every turn released, from the session's creation, as
      /// `RealtimeTranscriber`'s are: a turn released before the recording reads any
      /// waits in the stream, so a press is never lost to that race, and a
      /// session ended before `start` leaves a stream that has already ended.
      nonisolated let turns: AsyncThrowingStream<RealtimeTurn, any Error>
      private let feed: AsyncThrowingStream<RealtimeTurn, any Error>.Continuation
      private var script: [RealtimeTurn]

      private init(script: [RealtimeTurn]) {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: RealtimeTurn.self)
        turns = stream
        feed = continuation
        self.script = script
      }

      /// A new session over `script`, registered as the one the harness drives.
      nonisolated static func begin(script: [RealtimeTurn]) -> UITestLiveSession {
        let session = Self(script: script)
        current.withLock { $0 = session }
        return session
      }

      /// The session the newest recording opened, if any.
      nonisolated static func latest() -> UITestLiveSession? {
        current.withLock { $0 }
      }

      func start() {
        // Nothing to open: `turns` has been there since the session began.
      }

      func send(_: Data) {
        // Nothing listens: the turns come from the script.
      }

      func finish() {
        feed.finish()
      }

      func cancel() {
        feed.finish()
      }

      /// Releases the script's next turn.
      func next() {
        guard !script.isEmpty else {
          return
        }
        feed.yield(script.removeFirst())
      }

      /// Fails the session mid-recording, as a dropped connection does.
      func fail() {
        feed.finish(throwing: URLError(.networkConnectionLost))
      }
    }

    /// The model over `store`, with the canned transport behind both the
    /// async API and the gateway, and Record's doubles behind its capture and
    /// live transcription, writing to a throwaway folder — never the user's
    /// Recordings.
    static func uiTest(store: TranscriptStore) -> TranscriptsModel {
      let transport = UITestTranscriptTransport(
        speakerA: UITestIdentifiers.cannedFileSpeakerA,
        speakerB: UITestIdentifiers.cannedFileSpeakerB,
        title: UITestIdentifiers.cannedFileTitle,
        taskResult: UITestIdentifiers.cannedTaskResult
      )
      // Speaker A's partial, then its final; then speaker B's.
      let script = [
        RealtimeTurn(order: 0, transcript: UITestIdentifiers.livePartialA, isFinal: false, speaker: "A"),
        RealtimeTurn(order: 0, transcript: UITestIdentifiers.liveFinalA, isFinal: true, speaker: "A"),
        RealtimeTurn(order: 1, transcript: UITestIdentifiers.livePartialB, isFinal: false, speaker: "B"),
        RealtimeTurn(order: 1, transcript: UITestIdentifiers.liveFinalB, isFinal: true, speaker: "B"),
      ]
      let key = UITestIdentifiers.validAPIKey
      return TranscriptsModel(
        apiKey: { key },
        transcriber: FileTranscriber(client: AsyncTranscriptionClient(transport: transport, pollInterval: .zero)) {
          key
        },
        llm: TranscriptLLM(apiKeyProvider: { key }, transport: transport),
        store: store,
        recorder: UITestRecordingCapture(),
        liveSession: { _ in UITestLiveSession.begin(script: script) },
        recordingsDirectory: FileManager.default.temporaryDirectory.appending(
          path: "blurt-uitest-recordings-\(UUID().uuidString)",
          directoryHint: .isDirectory
        )
      )
    }
  }

#endif

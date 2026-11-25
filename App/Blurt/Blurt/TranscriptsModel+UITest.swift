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

      private var script: [RealtimeTurn]
      private var continuation: AsyncThrowingStream<RealtimeTurn, any Error>.Continuation?
      /// Turns asked for before the recording read any (`next` ahead of
      /// `start`), released as soon as it does: a press is never lost to that
      /// race.
      private var owed = 0
      /// Finished or cancelled: like `RealtimeTranscriber`, a session closed
      /// before `start` opens nothing, so a Stop that comes first can't wait
      /// on a stream that never ends.
      private var isClosed = false

      private init(script: [RealtimeTurn]) {
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

      func start() -> AsyncThrowingStream<RealtimeTurn, any Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: RealtimeTurn.self)
        guard !isClosed else {
          continuation.finish()
          return stream
        }
        self.continuation = continuation
        for _ in 0..<owed { next() }
        owed = 0
        return stream
      }

      func send(_: Data) {
        // Nothing listens: the turns come from the script.
      }

      func finish() {
        end(throwing: nil)
      }

      func cancel() {
        end(throwing: nil)
      }

      /// Releases the script's next turn, or owes it until the recording reads
      /// its turns.
      func next() {
        guard !script.isEmpty else {
          return
        }
        guard let reading = continuation else {
          owed += 1
          return
        }
        reading.yield(script.removeFirst())
      }

      /// Fails the session mid-recording, as a dropped connection does.
      func fail() {
        end(throwing: URLError(.networkConnectionLost))
      }

      private func end(throwing error: (any Error)?) {
        isClosed = true
        continuation?.finish(throwing: error)
        continuation = nil
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

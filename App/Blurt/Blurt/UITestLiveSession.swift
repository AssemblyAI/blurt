#if UITEST_HOOKS

  import AssemblyAI
  import Foundation
  import Synchronization

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
      let (stream, feed) = AsyncThrowingStream.makeStream(of: RealtimeTurn.self)
      guard !isClosed else {
        feed.finish()
        return stream
      }
      continuation = feed
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

#endif

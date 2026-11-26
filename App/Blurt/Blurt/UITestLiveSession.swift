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

#endif

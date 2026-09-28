import Foundation

public struct ShortTranscription: Sendable, Equatable {
  public let raw: String
  public let assemblyClean: String?
  public init(raw: String, assemblyClean: String?) {
    self.raw = raw
    self.assemblyClean = assemblyClean
  }
}

public protocol ShortSTTClient: Sendable {
  func transcribeShort(
    frames: AsyncStream<Data>, sampleRate: Int,
    context: TranscriptionContext?
  ) async throws -> ShortTranscription
}

public protocol LongSTTClient: Sendable {
  func transcribe(audioFileURL: URL, vocabulary: [String]) async throws -> String
}

public struct RoutedTranscription: Sendable, Equatable {
  public let mode: DictationPipelineMode
  public let raw: String
  public let assemblyClean: String?
}

public struct STTRouter: Sendable {
  public static let shortModeCutoverSeconds: TimeInterval = 115

  private let shortClient: any ShortSTTClient
  private let longClient: any LongSTTClient
  private let cutoverDelay: Duration

  public init(
    shortClient: any ShortSTTClient, longClient: any LongSTTClient,
    cutoverDelay: Duration = .seconds(STTRouter.shortModeCutoverSeconds)
  ) {
    self.shortClient = shortClient
    self.longClient = longClient
    self.cutoverDelay = cutoverDelay
  }

  public func start(
    frames: AsyncStream<Data>, writer: any LocalAudioWriter,
    context: TranscriptionContext?, vocabulary: [String],
    onCutover: @escaping @Sendable () -> Void = {}
  ) -> STTRoutingSession {
    start(
      frames: frames, writer: writer, contextProvider: { context },
      vocabulary: vocabulary, onCutover: onCutover)
  }

  /// Starts WAV persistence and the 115-second cutover immediately, while the
  /// short request may still be waiting briefly for press-time AX context.
  public func start(
    frames: AsyncStream<Data>, writer: any LocalAudioWriter,
    contextProvider: @escaping @Sendable () async -> TranscriptionContext?,
    vocabulary: [String], onCutover: @escaping @Sendable () -> Void = {}
  ) -> STTRoutingSession {
    let fanout = PCMFrameFanout(source: frames, writer: writer)
    let shortTask = Task {
      let context = await contextProvider()
      return try await shortClient.transcribeShort(
        frames: fanout.shortFrames, sampleRate: SyncSTTLimits.sampleRate,
        context: context)
    }
    let cutoverState = STTCutoverState()
    let cutoverTask = Task {
      try? await Task.sleep(for: cutoverDelay)
      guard !Task.isCancelled else { return }
      cutoverState.markReached()
      shortTask.cancel()
      fanout.stopShortFeed()
      onCutover()
    }
    return STTRoutingSession(
      shortTask: shortTask, cutoverTask: cutoverTask,
      audioCompletion: fanout.completion, longClient: longClient,
      vocabulary: vocabulary, stopShortFeed: { fanout.stopShortFeed() },
      cutoverState: cutoverState)
  }
}

public final class STTRoutingSession: Sendable {
  private let shortTask: Task<ShortTranscription, any Error>
  private let cutoverTask: Task<Void, Never>
  private let audioCompletion: Task<Void, any Error>
  private let longClient: any LongSTTClient
  private let vocabulary: [String]
  private let stopShortFeed: @Sendable () -> Void
  private let cutoverState: STTCutoverState

  fileprivate init(
    shortTask: Task<ShortTranscription, any Error>, cutoverTask: Task<Void, Never>,
    audioCompletion: Task<Void, any Error>, longClient: any LongSTTClient,
    vocabulary: [String], stopShortFeed: @escaping @Sendable () -> Void,
    cutoverState: STTCutoverState
  ) {
    self.shortTask = shortTask
    self.cutoverTask = cutoverTask
    self.audioCompletion = audioCompletion
    self.longClient = longClient
    self.vocabulary = vocabulary
    self.stopShortFeed = stopShortFeed
    self.cutoverState = cutoverState
  }

  public func stop(durationSeconds: TimeInterval, audioFileURL: URL) async throws -> RoutedTranscription {
    cutoverTask.cancel()
    try await audioCompletion.value
    if cutoverState.wasReached || durationSeconds >= STTRouter.shortModeCutoverSeconds {
      shortTask.cancel()
      stopShortFeed()
      let raw = try await longClient.transcribe(
        audioFileURL: audioFileURL, vocabulary: vocabulary)
      return RoutedTranscription(mode: .long, raw: raw, assemblyClean: nil)
    }
    let short = try await shortTask.value
    return RoutedTranscription(
      mode: .short, raw: short.raw, assemblyClean: short.assemblyClean)
  }

  public func cancel() {
    cutoverTask.cancel()
    shortTask.cancel()
    stopShortFeed()
    audioCompletion.cancel()
  }
}

final class STTCutoverState: Sendable {
  private let reached = Mutex(false)

  var wasReached: Bool { reached.withLock { $0 } }
  func markReached() { reached.withLock { $0 = true } }
}

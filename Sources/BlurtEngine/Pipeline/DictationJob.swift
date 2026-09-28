import Foundation

public struct DictationJob: Sendable, Equatable, Identifiable {
  public let id: UUID
  public let generation: UInt64
  public let createdAt: Date
  public var targetBundleIdentifier: String?
  public var targetAppName: String?
  public var targetWindowTitle: String?

  public init(
    id: UUID = UUID(), generation: UInt64, createdAt: Date = Date(),
    targetBundleIdentifier: String? = nil, targetAppName: String? = nil,
    targetWindowTitle: String? = nil
  ) {
    self.id = id
    self.generation = generation
    self.createdAt = createdAt
    self.targetBundleIdentifier = targetBundleIdentifier
    self.targetAppName = targetAppName
    self.targetWindowTitle = targetWindowTitle
  }
}

public struct VibeDictationPipeline: Sendable {
  public typealias AudioWriterFactory = @Sendable (UUID) throws -> any LocalAudioWriter

  public let router: STTRouter
  public let makeAudioWriter: AudioWriterFactory
  public let normalizer: (any TextNormalizer)?
  public let normalizationModel: @Sendable () -> String?
  public let onRecordChanged: @Sendable (DictationRecord) -> Void
  public let onRecordDiscarded: @Sendable (UUID) -> Void

  public init(
    router: STTRouter,
    makeAudioWriter: @escaping AudioWriterFactory = { try WAVAudioWriter(jobID: $0) },
    normalizer: (any TextNormalizer)? = nil,
    normalizationModel: @escaping @Sendable () -> String? = { nil },
    onRecordChanged: @escaping @Sendable (DictationRecord) -> Void = { _ in },
    onRecordDiscarded: @escaping @Sendable (UUID) -> Void = { _ in }
  ) {
    self.router = router
    self.makeAudioWriter = makeAudioWriter
    self.normalizer = normalizer
    self.normalizationModel = normalizationModel
    self.onRecordChanged = onRecordChanged
    self.onRecordDiscarded = onRecordDiscarded
  }
}

public enum DictationRecordStatus: String, Codable, Sendable {
  case processing
  case ready
  case failed
}

public enum DictationPipelineMode: String, Codable, Sendable {
  case short
  case long
}

public enum DictationInsertionStatus: String, Codable, Sendable {
  case notAttempted
  case inserted
  case targetLost
  case failed
}

public struct DictationRecord: Codable, Sendable, Equatable, Identifiable {
  public let id: UUID
  public let generation: UInt64
  public let createdAt: Date
  public var finishedAt: Date?
  public var durationMs: Int64
  public var status: DictationRecordStatus
  public var pipelineMode: DictationPipelineMode
  public var rawTranscript: String
  public var assemblyCleanTranscript: String?
  public var normalizedTranscript: String?
  public var targetBundleIdentifier: String?
  public var targetAppName: String?
  public var targetWindowTitle: String?
  public var audioRelativePath: String?
  public var sttProvider: String
  public var normalizationProvider: String?
  public var normalizationModel: String?
  public var insertionStatus: DictationInsertionStatus
  public var errorMessage: String?

  public init(
    job: DictationJob, durationMs: Int64 = 0, status: DictationRecordStatus = .processing,
    pipelineMode: DictationPipelineMode = .short, rawTranscript: String = "",
    assemblyCleanTranscript: String? = nil, normalizedTranscript: String? = nil,
    audioRelativePath: String? = nil, sttProvider: String = "AssemblyAI",
    normalizationProvider: String? = nil, normalizationModel: String? = nil,
    insertionStatus: DictationInsertionStatus = .notAttempted, errorMessage: String? = nil
  ) {
    id = job.id
    generation = job.generation
    createdAt = job.createdAt
    targetBundleIdentifier = job.targetBundleIdentifier
    targetAppName = job.targetAppName
    targetWindowTitle = job.targetWindowTitle
    finishedAt = nil
    self.durationMs = durationMs
    self.status = status
    self.pipelineMode = pipelineMode
    self.rawTranscript = rawTranscript
    self.assemblyCleanTranscript = assemblyCleanTranscript
    self.normalizedTranscript = normalizedTranscript
    self.audioRelativePath = audioRelativePath
    self.sttProvider = sttProvider
    self.normalizationProvider = normalizationProvider
    self.normalizationModel = normalizationModel
    self.insertionStatus = insertionStatus
    self.errorMessage = errorMessage
  }

  public var preferredText: String? {
    normalizedTranscript.trimmedNonEmpty()
      ?? assemblyCleanTranscript.trimmedNonEmpty()
      ?? rawTranscript.trimmedNonEmpty()
  }
}

public enum LatestDictationDecision: Sendable, Equatable {
  case noHistory
  case insert(recordID: UUID, text: String)
  case processing
  case failed
  case readyWithoutText

  public static func resolve(records: [DictationRecord]) -> LatestDictationDecision {
    guard let newest = records.max(by: { $0.createdAt < $1.createdAt }) else {
      return .noHistory
    }
    switch newest.status {
    case .processing:
      return .processing
    case .failed:
      return .failed
    case .ready:
      guard let text = newest.preferredText else { return .readyWithoutText }
      return .insert(recordID: newest.id, text: text)
    }
  }
}

public struct AutoInsertionEligibility: Sendable {
  public init() {}

  public func canInsert(
    job: DictationJob, newestGeneration: UInt64,
    currentBundleIdentifier: String?, currentWindowTitle: String?
  ) -> Bool {
    guard job.generation == newestGeneration else { return false }
    if let intendedBundle = job.targetBundleIdentifier {
      guard currentBundleIdentifier == intendedBundle else { return false }
    }
    if let intendedWindow = job.targetWindowTitle {
      guard currentWindowTitle == intendedWindow else { return false }
    }
    return true
  }
}

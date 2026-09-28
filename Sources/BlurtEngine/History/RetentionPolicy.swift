import Foundation

public protocol DateProviding: Sendable {
  var now: Date { get }
}

public struct SystemDateProvider: DateProviding {
  public init() {}
  public var now: Date { Date() }
}

public struct RetentionPolicy: Sendable {
  public static let audioDays = 3
  public static let historyDays = 30
  public static let cleanupInterval: TimeInterval = 24 * 60 * 60

  public init() {}

  public func apply(to records: [DictationRecord], now: Date) -> RetentionResult {
    let audioCutoff = now.addingTimeInterval(-TimeInterval(Self.audioDays * 24 * 60 * 60))
    let historyCutoff = now.addingTimeInterval(-TimeInterval(Self.historyDays * 24 * 60 * 60))
    var kept: [DictationRecord] = []
    var audioPathsToDelete: [String] = []
    var recordIDsToDelete: [UUID] = []
    for var record in records {
      if record.createdAt < historyCutoff {
        recordIDsToDelete.append(record.id)
        if let path = record.audioRelativePath { audioPathsToDelete.append(path) }
        continue
      }
      if record.createdAt < audioCutoff, let path = record.audioRelativePath {
        audioPathsToDelete.append(path)
        record.audioRelativePath = nil
      }
      kept.append(record)
    }
    return RetentionResult(
      records: kept, audioPathsToDelete: audioPathsToDelete,
      recordIDsToDelete: recordIDsToDelete)
  }

  public func shouldRun(lastCleanup: Date?, now: Date) -> Bool {
    guard let lastCleanup else { return true }
    return now.timeIntervalSince(lastCleanup) >= Self.cleanupInterval
  }
}

public struct RetentionResult: Sendable, Equatable {
  public let records: [DictationRecord]
  public let audioPathsToDelete: [String]
  public let recordIDsToDelete: [UUID]
}

public protocol AudioFileRemoving: Sendable {
  func remove(relativePath: String) throws
}

public struct ApplicationSupportAudioFileRemover: AudioFileRemoving {
  private let root: URL

  public init(root: URL) { self.root = root }

  public func remove(relativePath: String) throws {
    let url = root.appending(path: relativePath)
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    try FileManager.default.removeItem(at: url)
  }
}

public actor RetentionCleaner {
  private let history: any DictationHistoryStore
  private let files: any AudioFileRemoving
  private let dates: any DateProviding
  private let policy: RetentionPolicy
  private var lastCleanup: Date?

  public init(
    history: any DictationHistoryStore, files: any AudioFileRemoving,
    dates: any DateProviding = SystemDateProvider(), policy: RetentionPolicy = RetentionPolicy()
  ) {
    self.history = history
    self.files = files
    self.dates = dates
    self.policy = policy
  }

  @discardableResult
  public func runIfDue() async throws -> Bool {
    let now = dates.now
    guard policy.shouldRun(lastCleanup: lastCleanup, now: now) else { return false }
    let result = policy.apply(to: try await history.all(), now: now)
    for path in result.audioPathsToDelete { try files.remove(relativePath: path) }
    for id in result.recordIDsToDelete { try await history.delete(id: id) }
    let deleted = Set(result.recordIDsToDelete)
    for record in result.records where !deleted.contains(record.id) {
      try await history.upsert(record)
    }
    lastCleanup = now
    return true
  }
}

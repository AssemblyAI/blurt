import AppKit
import BlurtEngine
import Combine
import Foundation

@MainActor
final class HistoryModel: ObservableObject {
  @Published private(set) var records: [DictationRecord] = []
  @Published var selection: UUID?
  @Published var searchText = ""
  @Published var message: String?

  private var store: (any DictationHistoryStore)?
  private var cleaner: RetentionCleaner?
  private var cleanupTask: Task<Void, Never>?
  private var persistenceTail: Task<Void, Never>?
  let historyInjector = KeyInjector(pasteSettleDuration: .milliseconds(450))
  var playingSound: NSSound?
  private var generation: UInt64 = 0
  var activeRecord: DictationRecord?
  private var pendingRecords: [UUID: DictationRecord] = [:]
  private var pendingDeletions = Set<UUID>()

  init() {
    Task { await prepare() }
  }

  deinit {
    cleanupTask?.cancel()
    persistenceTail?.cancel()
  }

  var selectedRecord: DictationRecord? {
    records.first { $0.id == selection }
  }

  var historyStore: (any DictationHistoryStore)? { store }
  func reload() {
    Task { await load() }
  }

  /// Receives the authoritative record from DictationSession. The same UUID is
  /// upserted as raw STT, normalization and insertion finish; no UI-side shadow
  /// job is created. Values arriving while Core Data opens are retained.
  func recordChanged(_ record: DictationRecord) {
    guard let store else {
      pendingDeletions.remove(record.id)
      pendingRecords[record.id] = record
      return
    }
    enqueuePersistence { try await store.upsert(record) }
  }

  func recordDiscarded(_ id: UUID) {
    pendingRecords[id] = nil
    guard let store else {
      pendingDeletions.insert(id)
      return
    }
    enqueuePersistence { try await store.delete(id: id) }
  }

  func recordingStarted() {
    generation += 1
    let target = NSWorkspace.shared.frontmostApplication
    let job = DictationJob(
      generation: generation,
      targetBundleIdentifier: target?.bundleIdentifier,
      targetAppName: target?.localizedName)
    let record = DictationRecord(job: job, status: .processing)
    activeRecord = record
    Task {
      try? await store?.upsert(record)
      await load()
    }
  }

  func transcriptDelivered(_ text: String) {
    guard var record = activeRecord else { return }
    record.finishedAt = Date()
    record.status = .ready
    record.rawTranscript = text
    record.normalizedTranscript = text
    activeRecord = nil
    Task {
      try? await store?.upsert(record)
      await load()
    }
  }

  func dictationFailed(_ message: String) {
    guard var record = activeRecord else { return }
    record.finishedAt = Date()
    record.status = .failed
    record.errorMessage = message
    activeRecord = nil
    Task {
      try? await store?.upsert(record)
      await load()
    }
  }

  func dictationDiscarded() {
    guard let record = activeRecord else { return }
    activeRecord = nil
    Task {
      try? await store?.delete(id: record.id)
      await load()
    }
  }

  private func prepare() async {
    do {
      let history = try await CoreDataDictationHistoryStore()
      store = history
      let support = try Self.applicationSupportURL()
      let cleaner = RetentionCleaner(
        history: history,
        files: ApplicationSupportAudioFileRemover(root: support))
      self.cleaner = cleaner
      for id in pendingDeletions {
        enqueuePersistence { try await history.delete(id: id) }
      }
      for record in pendingRecords.values {
        enqueuePersistence { try await history.upsert(record) }
      }
      pendingDeletions.removeAll()
      pendingRecords.removeAll()
      try await cleaner.runIfDue()
      cleanupTask = Task { [weak self] in
        while !Task.isCancelled {
          try? await Task.sleep(for: .seconds(RetentionPolicy.cleanupInterval))
          guard let self else { return }
          _ = try? await self.cleaner?.runIfDue()
        }
      }
      await load()
    } catch { message = error.localizedDescription }
  }

  func load() async {
    guard let store else { return }
    do {
      if let query = searchText.trimmedNonEmpty() {
        records = try await store.search(query)
      } else {
        records = try await store.all()
      }
      if selection == nil { selection = records.first?.id }
    } catch { message = error.localizedDescription }
  }

  /// Core Data writes for one session are chained in callback order. Pipeline
  /// updates are intentionally incremental (processing → STT → normalized →
  /// inserted); unstructured Tasks could otherwise let an older processing
  /// snapshot overwrite the final ready record.
  func enqueuePersistence(
    _ operation: @escaping @Sendable () async throws -> Void
  ) {
    let previous = persistenceTail
    persistenceTail = Task { [weak self] in
      await previous?.value
      guard !Task.isCancelled else { return }
      try? await operation()
      await self?.load()
    }
  }

}

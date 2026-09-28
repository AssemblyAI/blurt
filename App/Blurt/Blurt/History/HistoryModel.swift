import AppKit
import BlurtEngine
import Combine
import Foundation

@MainActor
final class HistoryModel: ObservableObject {
  @Published private(set) var records: [DictationRecord] = []
  @Published var selection: UUID?
  @Published var searchText = ""
  @Published private(set) var message: String?

  private var store: (any DictationHistoryStore)?
  private var cleaner: RetentionCleaner?
  private var cleanupTask: Task<Void, Never>?
  private var persistenceTail: Task<Void, Never>?
  private let injector = KeyInjector(pasteSettleDuration: .milliseconds(450))
  private var sound: NSSound?
  private var generation: UInt64 = 0
  private var activeRecord: DictationRecord?
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

  func insertLast() {
    Task {
      guard let store else { return }
      do {
        let newest = try await store.newest()
        switch LatestDictationDecision.resolve(records: newest.map { [$0] } ?? []) {
        case .insert(let recordID, let text):
          try await injector.insert(recordID: recordID, text: text)
          message = "Последняя диктовка вставлена."
        case .processing:
          message = "Последняя диктовка ещё обрабатывается."
        case .failed:
          message = "Последняя диктовка завершилась ошибкой."
        case .noHistory:
          message = "История пока пуста."
        case .readyWithoutText:
          message = "В последней диктовке нет готового текста."
        }
      } catch {
        message = error.localizedDescription
      }
    }
  }

  func insert(_ record: DictationRecord) {
    guard let text = record.preferredText else { return }
    Task {
      do {
        try await injector.insert(recordID: record.id, text: text)
        message = "Текст вставлен."
      } catch { message = error.localizedDescription }
    }
  }

  func copy(_ record: DictationRecord) {
    guard let text = record.preferredText else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    message = "Текст скопирован."
  }

  func normalizeAgain(_ record: DictationRecord) {
    guard !record.rawTranscript.isEmpty else { return }
    Task {
      do {
        let normalizer = OpenRouterTextNormalizer(apiKeyProvider: { OpenRouterAPIKeyStore.current })
        let text = try await normalizer.normalize(
          rawTranscript: record.rawTranscript, vocabulary: VocabularyStore().terms)
        var updated = record
        updated.normalizedTranscript = text
        updated.normalizationProvider = "OpenRouter"
        updated.normalizationModel = OpenRouterModelStore().modelID
        updated.status = .ready
        try await store?.upsert(updated)
        await load()
      } catch { message = error.localizedDescription }
    }
  }

  func retryTranscription(_ record: DictationRecord) {
    guard let path = record.audioRelativePath,
      let audioURL = try? Self.applicationSupportURL().appending(path: path)
    else { return }
    Task {
      var updated = record
      updated.status = .processing
      updated.errorMessage = nil
      try? await store?.upsert(updated)
      await load()
      do {
        let raw = try await AssemblyAILongTranscriber().transcribe(
          audioFileURL: audioURL, vocabulary: VocabularyStore().terms)
        let normalized = try? await OpenRouterTextNormalizer(
          apiKeyProvider: { OpenRouterAPIKeyStore.current }
        ).normalize(rawTranscript: raw, vocabulary: VocabularyStore().terms)
        updated.finishedAt = Date()
        updated.pipelineMode = .long
        updated.rawTranscript = raw
        let normalizedText = normalized?.trimmedNonEmpty()
        updated.normalizedTranscript = normalizedText
        updated.normalizationProvider = normalizedText == nil ? nil : "OpenRouter"
        updated.normalizationModel = normalizedText == nil ? nil : OpenRouterModelStore().modelID
        updated.status = .ready
      } catch {
        updated.finishedAt = Date()
        updated.status = .failed
        updated.errorMessage = error.localizedDescription
      }
      try? await store?.upsert(updated)
      await load()
    }
  }

  func delete(_ record: DictationRecord) {
    Task {
      do {
        if let path = record.audioRelativePath, let url = try? Self.applicationSupportURL().appending(path: path) {
          try? FileManager.default.removeItem(at: url)
        }
        try await store?.delete(id: record.id)
        selection = nil
        await load()
      } catch { message = error.localizedDescription }
    }
  }

  func clearHistory() {
    Task {
      do {
        for record in try await store?.all() ?? [] {
          if let path = record.audioRelativePath,
            let url = try? Self.applicationSupportURL().appending(path: path)
          {
            try? FileManager.default.removeItem(at: url)
          }
        }
        try await store?.deleteAll()
        activeRecord = nil
        selection = nil
        await load()
        message = "История очищена."
      } catch { message = error.localizedDescription }
    }
  }

  func play(_ record: DictationRecord) {
    guard let path = record.audioRelativePath,
      let url = try? Self.applicationSupportURL().appending(path: path)
    else { return }
    sound = NSSound(contentsOf: url, byReference: true)
    sound?.play()
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

  private func load() async {
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
  private func enqueuePersistence(
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

  private static func applicationSupportURL() throws -> URL {
    try FileManager.default
      .url(
        for: .applicationSupportDirectory, in: .userDomainMask,
        appropriateFor: nil, create: true
      )
      .appending(path: "VibeDictate", directoryHint: .isDirectory)
  }
}

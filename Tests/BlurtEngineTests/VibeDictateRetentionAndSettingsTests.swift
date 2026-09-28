import Foundation
import Testing

@testable import BlurtEngine

@Suite("VibeDictate retention and settings")
struct VibeDictateRetentionAndSettingsTests {
  @Test("retention boundary and absent audio are harmless")
  func retentionBoundary() throws {
    let now = Date(timeIntervalSince1970: 10_000_000)
    let policy = RetentionPolicy()
    #expect(policy.shouldRun(lastCleanup: nil, now: now))
    #expect(!policy.shouldRun(lastCleanup: now.addingTimeInterval(-60), now: now))
    #expect(policy.shouldRun(lastCleanup: now.addingTimeInterval(-86_400), now: now))
    let record = DictationRecord(
      job: DictationJob(generation: 1, createdAt: now), audioRelativePath: nil)
    let result = policy.apply(to: [record], now: now)
    #expect(result.records == [record])
    #expect(result.audioPathsToDelete.isEmpty)
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try ApplicationSupportAudioFileRemover(root: folder).remove(relativePath: "missing.wav")
  }

  @Test("cleanup removes expired audio and history, then waits for the next interval")
  func cleanup() async throws {
    let now = Date(timeIntervalSince1970: 10_000_000)
    let store = try await CoreDataDictationHistoryStore(inMemory: true)
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let audio = folder.appending(path: "older.wav")
    try Data([1, 2]).write(to: audio)
    let stale = DictationRecord(
      job: DictationJob(generation: 1, createdAt: now.addingTimeInterval(-31 * 86_400)),
      audioRelativePath: "older.wav")
    let recent = DictationRecord(
      job: DictationJob(generation: 2, createdAt: now.addingTimeInterval(-4 * 86_400)),
      audioRelativePath: "older.wav")
    try await store.upsert(stale)
    try await store.upsert(recent)
    let cleaner = RetentionCleaner(
      history: store, files: ApplicationSupportAudioFileRemover(root: folder),
      dates: FixedDate(now: now))
    #expect(try await cleaner.runIfDue())
    #expect(!FileManager.default.fileExists(atPath: audio.path))
    #expect(try await store.record(id: stale.id) == nil)
    #expect(try await store.record(id: recent.id)?.audioRelativePath == nil)
    #expect(try await cleaner.runIfDue() == false)
  }

  @Test("vocabulary migrates key terms, then respects explicit saved removals")
  func vocabulary() throws {
    let suite = "VibeDictateVocabularyTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("NewTerm, Swift", forKey: KeyTermsStore.defaultsKey)
    let store = VocabularyStore(defaults: defaults)
    #expect(store.terms.contains("NewTerm"))
    #expect(store.terms.filter { $0.lowercased() == "swift" }.count == 1)
    store.save([" One ", "one", "Two"])
    #expect(store.terms == ["One", "Two"])
    store.add("Three")
    store.remove(" one ")
    #expect(store.terms == ["Two", "Three"])
  }

  @Test("OpenRouter model uses default, saves override and resets on blank")
  func model() throws {
    let suite = "VibeDictateModelTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = OpenRouterModelStore(defaults: defaults)
    #expect(store.modelID == OpenRouterTextNormalizer.defaultModel)
    store.save(" example/model ")
    #expect(store.modelID == "example/model")
    store.save(" ")
    #expect(store.modelID == OpenRouterTextNormalizer.defaultModel)
  }
}

private struct FixedDate: DateProviding {
  let now: Date
}

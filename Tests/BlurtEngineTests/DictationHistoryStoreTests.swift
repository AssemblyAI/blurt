import Foundation
import Testing

@testable import BlurtEngine

@Suite("Core Data dictation history", .serialized)
struct DictationHistoryStoreTests {
  @Test("newest is ordered by createdAt, not ready status")
  func newestIncludesProcessing() async throws {
    let store = try await CoreDataDictationHistoryStore(inMemory: true)
    let older = DictationRecord(
      job: DictationJob(generation: 1, createdAt: Date(timeIntervalSince1970: 1)),
      status: .ready, rawTranscript: "older")
    let newer = DictationRecord(
      job: DictationJob(generation: 2, createdAt: Date(timeIntervalSince1970: 2)),
      status: .processing)
    try await store.upsert(older)
    try await store.upsert(newer)
    #expect(try await store.newest()?.id == newer.id)
  }

  @Test("search matches raw and normalized transcripts")
  func search() async throws {
    let store = try await CoreDataDictationHistoryStore(inMemory: true)
    var first = DictationRecord(
      job: DictationJob(generation: 1), status: .ready,
      rawTranscript: "сырой PostgreSQL")
    first.normalizedTranscript = "готовый текст"
    try await store.upsert(first)
    #expect(try await store.search("postgres").map(\.id) == [first.id])
    #expect(try await store.search("готовый").map(\.id) == [first.id])
  }

  @Test("all pipeline snapshots upsert one UUID and survive a Core Data round trip")
  func pipelineSnapshots() async throws {
    let store = try await CoreDataDictationHistoryStore(inMemory: true)
    let job = DictationJob(
      id: UUID(), generation: 7, createdAt: Date(timeIntervalSince1970: 100),
      targetBundleIdentifier: "example.editor", targetAppName: "Editor",
      targetWindowTitle: "Draft")
    var record = DictationRecord(job: job, status: .processing)
    try await store.upsert(record)
    record.durationMs = 3_200
    record.pipelineMode = .long
    record.audioRelativePath = "Audio/\(job.id.uuidString).wav"
    record.rawTranscript = "сырой текст"
    record.sttProvider = "AssemblyAI Universal-2"
    try await store.upsert(record)
    record.normalizedTranscript = "готовый текст"
    record.normalizationProvider = "OpenRouter"
    record.normalizationModel = "test/model"
    record.status = .ready
    record.insertionStatus = .inserted
    record.finishedAt = Date(timeIntervalSince1970: 104)
    try await store.upsert(record)

    #expect(try await store.all() == [record])
    #expect(try await store.record(id: job.id) == record)
    #expect(try await store.search("готовый").map(\.id) == [job.id])
    try await store.delete(id: job.id)
    #expect(try await store.record(id: job.id) == nil)
  }

  @Test("deleteAll removes every saved dictation")
  func deleteAll() async throws {
    let store = try await CoreDataDictationHistoryStore(inMemory: true)
    try await store.upsert(DictationRecord(job: DictationJob(generation: 1)))
    try await store.upsert(DictationRecord(job: DictationJob(generation: 2)))
    #expect(try await store.all().count == 2)
    try await store.deleteAll()
    #expect(try await store.all().isEmpty)
  }
}

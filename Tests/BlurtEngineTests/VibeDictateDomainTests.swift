import Foundation
import Testing

@testable import BlurtEngine

@Suite("VibeDictate domain rules")
struct VibeDictateDomainTests {
  private func record(
    generation: UInt64, at date: Date, status: DictationRecordStatus,
    raw: String = "raw", clean: String? = nil, normalized: String? = nil,
    audio: String? = "audio.wav"
  ) -> DictationRecord {
    var value = DictationRecord(
      job: DictationJob(generation: generation, createdAt: date), status: status,
      rawTranscript: raw, assemblyCleanTranscript: clean,
      normalizedTranscript: normalized, audioRelativePath: audio)
    value.finishedAt = date
    return value
  }

  @Test("insertLastWhileNewestIsProcessingDoesNotInsertPrevious")
  func insertLastWhileNewestIsProcessingDoesNotInsertPrevious() {
    let now = Date()
    let older = record(generation: 1, at: now.addingTimeInterval(-1), status: .ready, normalized: "older")
    let newest = record(generation: 2, at: now, status: .processing)
    #expect(LatestDictationDecision.resolve(records: [older, newest]) == .processing)
  }

  @Test("insertLastWhileNewestFailedDoesNotInsertPrevious")
  func insertLastWhileNewestFailedDoesNotInsertPrevious() {
    let now = Date()
    let older = record(generation: 1, at: now.addingTimeInterval(-1), status: .ready, normalized: "older")
    let newest = record(generation: 2, at: now, status: .failed)
    #expect(LatestDictationDecision.resolve(records: [older, newest]) == .failed)
  }

  @Test("pasteUsesExactRecordPayload")
  func pasteUsesExactRecordPayload() {
    let newest = record(
      generation: 1, at: Date(), status: .ready, raw: "raw", clean: "clean",
      normalized: " exact normalized text ")
    #expect(
      LatestDictationDecision.resolve(records: [newest])
        == .insert(recordID: newest.id, text: "exact normalized text"))
  }

  @Test("outOfOrderCompletionCannotPasteOldTranscript")
  func outOfOrderCompletionCannotPasteOldTranscript() {
    let old = DictationJob(
      generation: 4, targetBundleIdentifier: "com.example.Editor",
      targetWindowTitle: "one")
    #expect(
      AutoInsertionEligibility().canInsert(
        job: old, newestGeneration: 5,
        currentBundleIdentifier: "com.example.Editor", currentWindowTitle: "one") == false)
  }

  @Test("lostTargetDoesNotPasteIntoWrongApplication")
  func lostTargetDoesNotPasteIntoWrongApplication() {
    let job = DictationJob(
      generation: 5, targetBundleIdentifier: "com.example.Editor",
      targetWindowTitle: "one")
    #expect(
      AutoInsertionEligibility().canInsert(
        job: job, newestGeneration: 5,
        currentBundleIdentifier: "com.example.Chat", currentWindowTitle: "one") == false)
  }

  @Test("openRouterFailureFallsBackToAssemblyClean")
  func openRouterFailureFallsBackToAssemblyClean() {
    #expect(NormalizationFallback.short(normalized: nil, assemblyClean: "clean", raw: "raw") == "clean")
  }

  @Test("shortPipelineRawFallbackWorks")
  func shortPipelineRawFallbackWorks() {
    #expect(NormalizationFallback.short(normalized: nil, assemblyClean: nil, raw: "raw") == "raw")
  }

  @Test("longPipelineOpenRouterFailureUsesRaw")
  func longPipelineOpenRouterFailureUsesRaw() {
    #expect(NormalizationFallback.long(normalized: nil, raw: "raw") == "raw")
  }

  @Test("audioDeletedAfterThreeDays")
  func audioDeletedAfterThreeDays() throws {
    let now = Date(timeIntervalSince1970: 4_000_000)
    let old = record(
      generation: 1, at: now.addingTimeInterval(-4 * 86_400), status: .ready)
    let result = RetentionPolicy().apply(to: [old], now: now)
    #expect(result.records.first?.audioRelativePath == nil)
    #expect(result.audioPathsToDelete == ["audio.wav"])
  }

  @Test("historyDeletedAfterThirtyDays")
  func historyDeletedAfterThirtyDays() {
    let now = Date(timeIntervalSince1970: 4_000_000)
    let old = record(
      generation: 1, at: now.addingTimeInterval(-31 * 86_400), status: .ready)
    let result = RetentionPolicy().apply(to: [old], now: now)
    #expect(result.records.isEmpty)
    #expect(result.recordIDsToDelete == [old.id])
    #expect(result.audioPathsToDelete == ["audio.wav"])
  }

  @Test("vocabularyIsDeduplicated")
  func vocabularyIsDeduplicated() {
    #expect(VocabularyStore.deduplicated([" Swift ", "swift", "", "OpenAI"]) == ["Swift", "OpenAI"])
  }
}

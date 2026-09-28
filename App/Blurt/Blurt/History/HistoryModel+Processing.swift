import BlurtEngine
import Foundation

extension HistoryModel {
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
        try await historyStore?.upsert(updated)
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
      try? await historyStore?.upsert(updated)
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
      try? await historyStore?.upsert(updated)
      await load()
    }
  }

  static func applicationSupportURL() throws -> URL {
    try FileManager.default
      .url(
        for: .applicationSupportDirectory, in: .userDomainMask,
        appropriateFor: nil, create: true
      )
      .appending(path: "VibeDictate", directoryHint: .isDirectory)
  }
}

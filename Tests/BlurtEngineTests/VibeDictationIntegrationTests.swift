import AppKit
import Foundation
import Testing

@testable import BlurtEngine

@Suite("VibeDictate session integration", .timeLimit(.minutes(1)))
struct VibeDictationIntegrationTests {
  @Test("short route persists every transcript stage under one job id")
  func shortRouteEndToEnd() async {
    let records = IntegrationRecordBox()
    let injector = IntegrationInjector()
    let mic = StubMicCapture()
    let writer = IntegrationAudioWriter()
    let pipeline = VibeDictationPipeline(
      router: STTRouter(
        shortClient: IntegrationShortClient(), longClient: IntegrationLongClient(),
        cutoverDelay: .seconds(60)),
      makeAudioWriter: { _ in writer },
      normalizer: IntegrationNormalizer(result: .success("normalized")),
      normalizationModel: { "test/model" },
      onRecordChanged: { records.append($0) })
    let session = DictationSession(
      mic: mic, transcriber: StubTranscriber(mode: .transcript("unused")), injector: injector,
      keyTermsProvider: { ["Swift"] }, textShortcutsProvider: { [] },
      vibePipeline: pipeline, seams: .offline)

    await session.press()
    await session.release()
    await session.awaitPipeline()

    let final = records.values.last
    #expect(await session.phase == .pasted)
    #expect(final?.rawTranscript == "raw")
    #expect(final?.assemblyCleanTranscript == "assembly clean")
    #expect(final?.normalizedTranscript == "normalized")
    #expect(final?.pipelineMode == .short)
    #expect(final?.sttProvider == "AssemblyAI Dictation API")
    #expect(final?.insertionStatus == .inserted)
    #expect(final?.audioRelativePath == "Audio/integration.wav")
    #expect(final?.durationMs ?? 0 > 0)
    #expect(Set(records.values.map(\.id)).count == 1)
    #expect(injector.recordID == final?.id)
    #expect(injector.text == "normalized")
  }

  @Test("cutover keeps WAV capture alive and long route falls back to raw")
  func longRouteEndToEnd() async {
    let records = IntegrationRecordBox()
    let injector = IntegrationInjector()
    let mic = StubMicCapture()
    let writer = IntegrationAudioWriter()
    let long = IntegrationLongClient()
    let pipeline = VibeDictationPipeline(
      router: STTRouter(
        shortClient: IntegrationShortClient(waitForCancellation: true),
        longClient: long, cutoverDelay: .zero),
      makeAudioWriter: { _ in writer },
      normalizer: IntegrationNormalizer(result: .failure(IntegrationFailure.failed)),
      onRecordChanged: { records.append($0) })
    let session = DictationSession(
      mic: mic, transcriber: StubTranscriber(mode: .transcript("unused")), injector: injector,
      keyTermsProvider: { ["OpenRouter"] }, textShortcutsProvider: { [] },
      vibePipeline: pipeline, seams: .offline)

    await session.press()
    while await session.phase != .longMode { await Task.yield() }
    #expect(await session.phase == .longMode)
    await session.release()
    await session.awaitPipeline()

    let final = records.values.last
    #expect(await session.phase == .pasted)
    #expect(final?.pipelineMode == .long)
    #expect(final?.sttProvider == "AssemblyAI Universal-2")
    #expect(final?.rawTranscript == "long raw")
    #expect(final?.assemblyCleanTranscript == nil)
    #expect(final?.normalizedTranscript == nil)
    #expect(injector.text == "long raw")
    #expect(long.vocabulary == ["OpenRouter"])
    #expect(writer.bytes == StubPCM.aboveMinimum)
  }

  @Test("cancel during STT removes the WAV and processing record")
  func cancelDuringTranscription() async {
    let records = IntegrationRecordBox()
    let writer = IntegrationAudioWriter()
    let injector = IntegrationInjector()
    let pipeline = VibeDictationPipeline(
      router: STTRouter(
        shortClient: IntegrationShortClient(waitForCancellation: true),
        longClient: IntegrationLongClient()),
      makeAudioWriter: { _ in writer },
      onRecordChanged: { records.append($0) },
      onRecordDiscarded: { records.discard($0) })
    let session = DictationSession(
      mic: StubMicCapture(), transcriber: StubTranscriber(mode: .transcript("unused")),
      injector: injector, vibePipeline: pipeline, seams: .offline)

    await session.press()
    await session.release()
    while await session.phase != .transcribing { await Task.yield() }
    await session.cancel()
    await session.awaitPipeline()

    #expect(await session.phase == .cancelled)
    #expect(writer.bytes.isEmpty)
    #expect(records.discarded == records.values.first?.id)
    #expect(injector.recordID == nil)
  }
}

private enum IntegrationFailure: Error, Sendable { case failed }

private struct IntegrationShortClient: ShortSTTClient {
  let waitForCancellation: Bool

  init(waitForCancellation: Bool = false) {
    self.waitForCancellation = waitForCancellation
  }

  func transcribeShort(
    frames: AsyncStream<Data>, sampleRate: Int, context: TranscriptionContext?
  ) async throws -> ShortTranscription {
    for await _ in frames {}
    if waitForCancellation { try await Task.sleep(for: .seconds(60)) }
    return ShortTranscription(raw: "raw", assemblyClean: "assembly clean")
  }
}

private final class IntegrationLongClient: LongSTTClient, Sendable {
  private let terms = Mutex<[String]>([])

  func transcribe(audioFileURL: URL, vocabulary: [String]) async throws -> String {
    terms.withLock { $0 = vocabulary }
    return "long raw"
  }

  var vocabulary: [String] { terms.withLock { $0 } }
}

private struct IntegrationNormalizer: TextNormalizer {
  let result: Result<String, IntegrationFailure>

  func normalize(rawTranscript: String, vocabulary: [String]) async throws -> String {
    try result.get()
  }
}

private final class IntegrationAudioWriter: LocalAudioWriter, Sendable {
  private let data = Mutex(Data())
  var relativePath: String { get async { "Audio/integration.wav" } }
  var fileURL: URL { get async { URL(fileURLWithPath: "/tmp/integration.wav") } }
  func append(_ pcm: Data) async throws { data.withLock { $0.append(pcm) } }
  func finish() async throws {}
  func cancelAndDelete() async { data.withLock { $0.removeAll() } }
  var bytes: Data { data.withLock { $0 } }
}

private final class IntegrationInjector: InjectorProtocol, Sendable {
  private struct State {
    var recordID: UUID?
    var text: String?
  }
  private let state = Mutex(State())

  func setTargetApp(_ app: NSRunningApplication?) async {}
  func insert(_ text: String, after priorText: String?, windowTitle: String?) async throws {}
  func insert(
    recordID: UUID, text: String, after priorText: String?, windowTitle: String?
  ) async throws {
    state.withLock { $0 = State(recordID: recordID, text: text) }
  }
  var recordID: UUID? { state.withLock { $0.recordID } }
  var text: String? { state.withLock { $0.text } }
}

private final class IntegrationRecordBox: Sendable {
  private struct State {
    var values: [DictationRecord] = []
    var discarded: UUID?
  }
  private let state = Mutex(State())
  func append(_ record: DictationRecord) { state.withLock { $0.values.append(record) } }
  func discard(_ id: UUID) { state.withLock { $0.discarded = id } }
  var values: [DictationRecord] { state.withLock { $0.values } }
  var discarded: UUID? { state.withLock { $0.discarded } }
}

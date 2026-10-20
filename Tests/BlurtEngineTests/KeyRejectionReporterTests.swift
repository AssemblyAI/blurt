import Foundation
import Synchronization
import Testing

@testable import BlurtEngine

/// A dictation refused for its key is reported (so a signed-in account renews
/// at once) and still fails, with the error unchanged.
@Suite("Key rejection reporter")
struct KeyRejectionReporterTests {
  /// Answers every dictation with `outcome`.
  private struct Answering: TranscriberProtocol {
    let outcome: Result<String, AssemblyAIError>
    let warmUps: Counter

    func transcribe(
      frames: AsyncStream<Data>, sampleRate: Int, context: TranscriptionContext?
    ) async throws -> String {
      try outcome.get()
    }

    func warmUp() async { _ = warmUps.next() }
  }

  private func run(_ outcome: Result<String, AssemblyAIError>) async -> (reported: Int, error: (any Error)?) {
    let reports = Counter()
    let reporter = KeyRejectionReporter(Answering(outcome: outcome, warmUps: Counter())) { _ = reports.next() }
    do {
      _ = try await reporter.transcribe(frames: AsyncStream { $0.finish() }, sampleRate: 16_000, context: nil)
      return (reports.value, nil)
    } catch {
      return (reports.value, error)
    }
  }

  @Test("a 401 or the API's invalid-key 404 is reported and rethrown as is")
  func rejected() async {
    for status in [401, 404] {
      let (reported, error) = await run(.failure(.http(status: status, message: "Invalid API key")))
      #expect(reported == 1, "status \(status)")
      guard case .http(let thrown, let message)? = error as? AssemblyAIError else {
        Issue.record("status \(status): \(String(describing: error))")
        continue
      }
      #expect(thrown == status)
      #expect(message == "Invalid API key")
    }
  }

  @Test("other failures and successes aren't reported")
  func notRejected() async {
    #expect(await run(.failure(.http(status: 500, message: nil))).reported == 0)
    #expect(await run(.failure(.malformedResponse)).reported == 0)
    let (reported, error) = await run(.success("hello"))
    #expect(reported == 0)
    #expect(error == nil)
  }

  @Test("warm-up goes to the wrapped transcriber")
  func warmUp() async {
    let warmUps = Counter()
    await KeyRejectionReporter(Answering(outcome: .success(""), warmUps: warmUps)) {}.warmUp()
    #expect(warmUps.value == 1)
  }
}

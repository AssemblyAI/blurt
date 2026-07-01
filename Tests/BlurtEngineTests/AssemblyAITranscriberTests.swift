import Foundation
import Testing

@testable import BlurtEngine

/// Tests for the HTTP-backed API clients. The `AssemblyAITranscriber` cases live
/// here; the `APIKeyValidator` cases live in `APIKeyValidatorTests.swift` as an
/// extension of this same suite. They are one suite, not two, because they share
/// the process-global `MockURLProtocol.responder`: two independent suites would
/// run in parallel and clobber each other's responder (or its `defer` cleanup)
/// mid-request. `.serialized` keeps the whole group sequential. The mock itself
/// lives in `Stubs/MockURLProtocol.swift`.
@Suite("HTTP network clients", .serialized)
struct HTTPClientTests {

  @Test("transcriber posts to the sync endpoint and returns the transcript")
  func transcribeHappyPath() async throws {
    let hits = Counter()
    MockURLProtocol.responder = { request in
      _ = hits.next()
      guard request.url?.path.hasSuffix("/transcribe") == true,
        request.httpMethod == "POST"
      else { return (404, Data()) }
      return (200, json(["text": "hello world"]))
    }
    defer { MockURLProtocol.responder = nil }

    let result = try await collectTranscript(makeTranscriber(apiKey: "test-key"))
    #expect(result == "hello world")
    // Single round-trip: no upload/submit/poll fan-out.
    #expect(hits.value == 1)
  }

  @Test("transcriber succeeds with a real context (builds and sends a prompt)")
  func transcribeWithContext() async throws {
    MockURLProtocol.responder = { request in
      guard request.url?.path.hasSuffix("/transcribe") == true else { return (404, Data()) }
      return (200, json(["text": "hello world"]))
    }
    defer { MockURLProtocol.responder = nil }

    // A non-empty context exercises the TranscriptionPrompt.build path inside
    // transcribe() that the nil-context happy path skips. The mock can't observe
    // the multipart upload body, so this asserts the request still round-trips
    // cleanly rather than the wire contents (covered directly by makeConfigData).
    let result = try await makeTranscriber(apiKey: "test-key")
      .transcribe(
        samples: [0, 0.1, -0.1],
        sampleRate: 16_000,
        context: TranscriptionContext(appName: "Slack", priorText: "Dear Sam,"))
    #expect(result == "hello world")
  }

  @Test("warmUp issues a single GET to the host so the connection is pre-opened")
  func warmUpPreOpensConnection() async throws {
    let hits = Counter()
    let getHits = Counter()
    MockURLProtocol.responder = { request in
      _ = hits.next()
      if request.httpMethod == "GET", request.url?.path.hasSuffix("/transcribe") == false {
        _ = getHits.next()
      }
      return (404, Data())
    }
    defer { MockURLProtocol.responder = nil }

    // warmUp is fire-and-forget and swallows errors; it should still issue
    // exactly one lightweight GET (no /transcribe POST, no auth) to establish
    // the pooled connection the next transcribe reuses.
    await makeTranscriber(apiKey: "test-key").warmUp()
    #expect(hits.value == 1)
    #expect(getHits.value == 1)
  }

  @Test("transcriber throws apiKeyMissing when no key is configured")
  func transcribeMissingKey() async throws {
    await #expect(throws: BlurtError.apiKeyMissing) {
      _ = try await collectTranscript(makeTranscriber(apiKey: nil))
    }
  }

  @Test("transcriber throws when the response omits transcript text")
  func transcribeMalformedResponse() async throws {
    MockURLProtocol.responder = { _ in (200, json(["confidence": "0.9"])) }
    defer { MockURLProtocol.responder = nil }

    await #expect(throws: (any Error).self) {
      _ = try await collectTranscript(makeTranscriber(apiKey: "test-key"))
    }
  }

  @Test("transcriber throws on non-2xx HTTP responses")
  func transcribeHTTPError() async throws {
    MockURLProtocol.responder = { _ in (401, json(["message": "Invalid API key"])) }
    defer { MockURLProtocol.responder = nil }

    await #expect(throws: (any Error).self) {
      _ = try await collectTranscript(makeTranscriber(apiKey: "bad-key"))
    }
  }

  @Test("config part carries the built context prompt")
  func configIncludesPrompt() throws {
    let config = try makeTranscriber(apiKey: "test-key")
      .makeConfigData(sampleRate: 16_000, prompt: "CONTEXT. Transcribe.")
    let object = try JSONSerialization.jsonObject(with: config) as? [String: Any]
    #expect(object?["prompt"] as? String == "CONTEXT. Transcribe.")
    #expect(object?["sample_rate"] as? Int == 16_000)
  }

  @Test("config part omits the prompt field when there is no context")
  func configOmitsPromptWhenNil() throws {
    let config = try makeTranscriber(apiKey: "test-key")
      .makeConfigData(sampleRate: 16_000, prompt: nil)
    let object = try JSONSerialization.jsonObject(with: config) as? [String: Any]
    #expect(object?.keys.contains("prompt") == false)
  }

  @Test("config part omits the prompt field when the prompt is only whitespace")
  func configOmitsBlankPrompt() throws {
    let config = try makeTranscriber(apiKey: "test-key")
      .makeConfigData(sampleRate: 16_000, prompt: "   \n")
    let object = try JSONSerialization.jsonObject(with: config) as? [String: Any]
    #expect(object?.keys.contains("prompt") == false)
  }

  @Test("transcriber HTTP error carries the decoded server message")
  func transcribeHTTPErrorMessage() async throws {
    MockURLProtocol.responder = { _ in (422, json(["message": "audio too long"])) }
    defer { MockURLProtocol.responder = nil }

    // The transcriber surfaces its transport error directly; DictationSession is
    // the layer that wraps it in BlurtError.sttFailed before it reaches the UI.
    do {
      _ = try await collectTranscript(makeTranscriber(apiKey: "k"))
      Issue.record("expected a throw")
    } catch let AssemblyAIError.http(status, message) {
      #expect(status == 422)
      #expect(message == "audio too long")
    } catch {
      Issue.record("expected AssemblyAIError.http, got \(error)")
    }
  }

  @Test("HTTP error message is read from the `error` field too, not just `message`")
  func errorMessageFromErrorField() async throws {
    MockURLProtocol.responder = { _ in (400, json(["error": "audio too short"])) }
    defer { MockURLProtocol.responder = nil }

    do {
      _ = try await collectTranscript(makeTranscriber(apiKey: "k"))
      Issue.record("expected a throw")
    } catch let AssemblyAIError.http(status, message) {
      #expect(status == 400)
      #expect(message == "audio too short")
    } catch {
      Issue.record("expected AssemblyAIError.http, got \(error)")
    }
  }

  @Test("HTTP error falls back to the raw body when the shape is unknown")
  func errorMessageFallsBackToRawBody() {
    let body = Data(#"{"unexpected":"shape"}"#.utf8)
    #expect(AssemblyAITranscriber.errorMessage(from: body) == #"{"unexpected":"shape"}"#)
  }

  @Test("HTTP error message is nil only for an empty body")
  func errorMessageNilForEmptyBody() {
    #expect(AssemblyAITranscriber.errorMessage(from: Data()) == nil)
    #expect(AssemblyAITranscriber.errorMessage(from: Data("   \n".utf8)) == nil)
  }

  @Test("transcriber constructs with production defaults (no overrides)")
  func transcriberDefaultInit() {
    // Exercises the default baseURL / urlSession parameter values — the path the
    // real app uses — without issuing any request.
    _ = AssemblyAITranscriber(apiKeyProvider: { nil })
  }

  @Test("AssemblyAIError descriptions are non-empty and include the status")
  func assemblyAIErrorDescriptions() {
    #expect(AssemblyAIError.http(status: 500, message: "boom").errorDescription == "AssemblyAI error 500: boom")
    #expect(AssemblyAIError.http(status: 503, message: nil).errorDescription == "AssemblyAI error 503")
    #expect(AssemblyAIError.malformedResponse.errorDescription?.isEmpty == false)
  }

  // MARK: - helpers

  private func makeTranscriber(apiKey: String?) -> AssemblyAITranscriber {
    AssemblyAITranscriber(
      apiKeyProvider: { apiKey },
      baseURL: URL(string: "https://sync.assemblyai.com")!,
      urlSession: mockURLSession()
    )
  }

  private func collectTranscript(_ transcriber: AssemblyAITranscriber) async throws -> String {
    try await transcriber.transcribe(samples: [0, 0.1, -0.1], sampleRate: 16_000, context: nil)
  }
}

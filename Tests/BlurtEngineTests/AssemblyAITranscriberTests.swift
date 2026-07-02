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

  @Test("transcribe sends the raw key and the sync model selector as headers")
  func transcribeSendsAuthAndModelHeaders() async throws {
    MockURLProtocol.responder = { request in
      // The wire contract: the raw key in Authorization (no "Bearer" prefix),
      // the sync model selector, and a boundary-tagged multipart body. Anything
      // else gets a 400 so a header regression fails loudly here.
      guard request.value(forHTTPHeaderField: "Authorization") == "test-key",
        request.value(forHTTPHeaderField: "X-AAI-Model") == "u3-sync-pro",
        request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true
      else { return (400, Data()) }
      return (200, json(["text": "ok"]))
    }
    defer { MockURLProtocol.responder = nil }

    #expect(try await collectTranscript(makeTranscriber(apiKey: "test-key")) == "ok")
  }

  @Test("warmUp issues a single GET to the host so the connection is pre-opened")
  func warmUpPreOpensConnection() async throws {
    let hits = Counter()
    let getHits = Counter()
    MockURLProtocol.responder = { request in
      _ = hits.next()
      // The warm-up must be a bare, auth-less GET off the /transcribe path —
      // carrying the key or model header would make it count as a transcription.
      if request.httpMethod == "GET", request.url?.path.hasSuffix("/transcribe") == false,
        request.value(forHTTPHeaderField: "Authorization") == nil,
        request.value(forHTTPHeaderField: "X-AAI-Model") == nil
      {
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

  @Test("transcriber treats an empty-string key as missing, without a request")
  func transcribeEmptyKeyIsMissing() async throws {
    let hits = Counter()
    MockURLProtocol.responder = { _ in
      _ = hits.next()
      return (200, json(["text": "never"]))
    }
    defer { MockURLProtocol.responder = nil }

    // A cleared Keychain item can come back as "" rather than nil — that must
    // fail fast as a missing key, not go to the wire with a blank Authorization.
    await #expect(throws: BlurtError.apiKeyMissing) {
      _ = try await collectTranscript(makeTranscriber(apiKey: ""))
    }
    #expect(hits.value == 0)
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
    // The capture path is mono by construction; the declared geometry must agree.
    #expect(object?["channels"] as? Int == 1)
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

  @Test("HTTP error message is read from the `detail` field too")
  func errorMessageFromDetailField() {
    #expect(AssemblyAITranscriber.errorMessage(from: json(["detail": "audio required"])) == "audio required")
  }

  @Test("HTTP error message field precedence is error > message > detail")
  func errorMessageFieldPrecedence() {
    // The API labels its explanation inconsistently; when several fields
    // co-exist the documented priority must hold, so a reorder can't silently
    // change which message reaches the user.
    #expect(
      AssemblyAITranscriber.errorMessage(from: json(["error": "a", "message": "b", "detail": "c"])) == "a")
    #expect(AssemblyAITranscriber.errorMessage(from: json(["message": "b", "detail": "c"])) == "b")
  }

  @Test("a non-string `detail` (validation array) falls back to the raw body")
  func errorMessageNonStringDetailFallsBack() {
    // FastAPI-style validation errors carry `detail` as an array; that must not
    // decode as the message — the raw body is still more useful than nothing.
    let body = #"{"detail":[{"loc":["config"],"msg":"field required"}]}"#
    #expect(AssemblyAITranscriber.errorMessage(from: Data(body.utf8)) == body)
  }

  @Test("a raw-body error message is capped at 500 characters")
  func errorMessageRawBodyCapped() {
    // An HTML error page must not flood the overlay/error description.
    let long = String(repeating: "x", count: 600)
    #expect(AssemblyAITranscriber.errorMessage(from: Data(long.utf8))?.count == 500)
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

import Foundation
import Testing

@testable import BlurtEngine

/// Tests for the HTTP-backed API clients. The `AssemblyAITranscriber` cases live
/// here; the `APIKeyValidator` cases live in `APIKeyValidatorTests.swift` as an
/// extension of this same suite. They share only the `makeTranscriber`/
/// `makeValidator` helpers and the `FakeHTTPTransport` seam — each test wires its
/// own per-instance transport, so no process-global state forces `.serialized`.
@Suite("HTTP network clients")
struct HTTPClientTests {

  @Test("transcriber posts to the dictation endpoint and returns the rewritten text")
  func transcribeHappyPath() async throws {
    let hits = Counter()
    let transport = FakeHTTPTransport { request in
      _ = hits.next()
      guard request.url?.path.hasSuffix("/transcribe") == true,
        request.httpMethod == "POST"
      else { return (404, Data()) }
      return (200, json(["text": "um hello world", "llm_response": "Hello world."]))
    }

    let result = try await collectTranscript(makeTranscriber(apiKey: "test-key", transport: transport))
    // The LLM rewrite — not the verbatim transcript — is what gets pasted.
    #expect(result == "Hello world.")
    // Single round-trip: transcription + rewrite ride one request, no fan-out.
    #expect(hits.value == 1)
  }

  @Test("transcriber falls back to the verbatim transcript when no rewrite came back")
  func transcribeFallsBackWithoutRewrite() async throws {
    // A null / absent `llm_response` (the rewrite is best-effort) must degrade
    // to the verbatim transcript, never to an error or an empty paste.
    for body in [
      Data(#"{"text":"hello world","llm_response":null,"llm_error":"timeout"}"#.utf8),
      json(["text": "hello world"]),
    ] {
      let transport = FakeHTTPTransport { _ in (200, body) }
      let result = try await collectTranscript(makeTranscriber(apiKey: "test-key", transport: transport))
      #expect(result == "hello world")
    }
  }

  @Test("transcriber succeeds with a real context (builds and sends a prompt)")
  func transcribeWithContext() async throws {
    let transport = FakeHTTPTransport { request in
      guard request.url?.path.hasSuffix("/transcribe") == true else { return (404, Data()) }
      return (200, json(["text": "hello world"]))
    }

    // A non-empty context exercises the TranscriptionPrompt.build path inside
    // transcribe() that the nil-context happy path skips. The fake can't observe
    // the multipart upload body, so this asserts the request still round-trips
    // cleanly rather than the wire contents (covered directly by makeConfigData).
    let result = try await makeTranscriber(apiKey: "test-key", transport: transport)
      .transcribe(
        pcm: Self.testPCM,
        sampleRate: 16_000,
        context: TranscriptionContext(appName: "Slack", priorText: "Dear Sam,"))
    #expect(result == "hello world")
  }

  @Test("transcribe sends the raw key, no model header, and the documented timeout")
  func transcribeSendsAuthAndModelHeaders() async throws {
    let transport = FakeHTTPTransport { request in
      // The wire contract: the raw key in Authorization (no "Bearer" prefix), a
      // boundary-tagged multipart body, no `X-AAI-Model` (the dictation service
      // pins the STT model server-side), and the API's documented 90 s client
      // timeout. Anything else gets a 400 so a regression fails loudly here.
      guard request.value(forHTTPHeaderField: "Authorization") == "test-key",
        request.value(forHTTPHeaderField: "X-AAI-Model") == nil,
        request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true,
        request.timeoutInterval == 90
      else { return (400, Data()) }
      return (200, json(["text": "ok"]))
    }

    #expect(try await collectTranscript(makeTranscriber(apiKey: "test-key", transport: transport)) == "ok")
  }

  @Test("warmUp issues a single GET to the host so the connection is pre-opened")
  func warmUpPreOpensConnection() async throws {
    let hits = Counter()
    let getHits = Counter()
    let transport = FakeHTTPTransport { request in
      _ = hits.next()
      // The warm-up must be a bare, auth-less GET off the /transcribe path —
      // carrying the key would make it count as a transcription.
      if request.httpMethod == "GET", request.url?.path.hasSuffix("/transcribe") == false,
        request.value(forHTTPHeaderField: "Authorization") == nil
      {
        _ = getHits.next()
      }
      return (404, Data())
    }

    // warmUp is fire-and-forget and swallows errors; it should still issue
    // exactly one lightweight GET (no /transcribe POST, no auth) to establish
    // the pooled connection the next transcribe reuses.
    await makeTranscriber(apiKey: "test-key", transport: transport).warmUp()
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
    let transport = FakeHTTPTransport { _ in
      _ = hits.next()
      return (200, json(["text": "never"]))
    }

    // A cleared Keychain item can come back as "" rather than nil — that must
    // fail fast as a missing key, not go to the wire with a blank Authorization.
    await #expect(throws: BlurtError.apiKeyMissing) {
      _ = try await collectTranscript(makeTranscriber(apiKey: "", transport: transport))
    }
    #expect(hits.value == 0)
  }

  @Test("transcriber throws when the response omits transcript text")
  func transcribeMalformedResponse() async throws {
    let transport = FakeHTTPTransport { _ in (200, json(["confidence": "0.9"])) }

    await #expect(throws: (any Error).self) {
      _ = try await collectTranscript(makeTranscriber(apiKey: "test-key", transport: transport))
    }
  }

  @Test("transcriber throws on non-2xx HTTP responses")
  func transcribeHTTPError() async throws {
    let transport = FakeHTTPTransport { _ in (401, json(["message": "Invalid API key"])) }

    await #expect(throws: (any Error).self) {
      _ = try await collectTranscript(makeTranscriber(apiKey: "bad-key", transport: transport))
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

  @Test("config part always requests the default cleanup rewrite")
  func configRequestsDefaultRewrite() throws {
    // `llm` must be present and empty on every request: present so the service
    // runs the rewrite at all, empty so the server-owned default cleanup
    // instruction (and its guardrails) applies rather than a client-side copy.
    for prompt in ["CONTEXT. Transcribe.", nil] {
      let config = try makeTranscriber(apiKey: "test-key")
        .makeConfigData(sampleRate: 16_000, prompt: prompt)
      let object = try JSONSerialization.jsonObject(with: config) as? [String: Any]
      let llm = object?["llm"] as? [String: Any]
      #expect(llm != nil)
      #expect(llm?.isEmpty == true)
    }
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
    let transport = FakeHTTPTransport { _ in (422, json(["message": "audio too long"])) }

    // The transcriber surfaces its transport error directly; DictationSession is
    // the layer that wraps it in BlurtError.sttFailed before it reaches the UI.
    do {
      _ = try await collectTranscript(makeTranscriber(apiKey: "k", transport: transport))
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
    let transport = FakeHTTPTransport { _ in (400, json(["error": "audio too short"])) }

    do {
      _ = try await collectTranscript(makeTranscriber(apiKey: "k", transport: transport))
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
    // Exercises the default baseURL / transport parameter values — the path the
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

  /// Builds a transcriber wired to `transport`. The default transport answers
  /// every request with a 500, for the cases that must never reach the wire.
  private func makeTranscriber(
    apiKey: String?,
    transport: any HTTPTransport = FakeHTTPTransport { _ in (500, Data()) }
  ) -> AssemblyAITranscriber {
    AssemblyAITranscriber(apiKeyProvider: { apiKey }, transport: transport)
  }

  private func collectTranscript(_ transcriber: AssemblyAITranscriber) async throws -> String {
    try await transcriber.transcribe(pcm: Self.testPCM, sampleRate: 16_000, context: nil)
  }

  /// Three arbitrary S16LE samples — the raw blob shape `MicCapture.stop()`
  /// hands the transcriber.
  private static let testPCM = Data([0x00, 0x00, 0xCD, 0x0C, 0x33, 0xF3])
}

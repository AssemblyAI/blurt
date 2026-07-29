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

  /// The whole rewrite-selection rule, one row per response shape: a usable
  /// `llm_response` wins (even when an `llm_error` marks it degraded), and
  /// anything unusable — null, absent, or blank — falls back to the verbatim
  /// `text`. The blank rows are the ones that bite: a "" reaching the pipeline's
  /// whitespace guard drops the utterance to `.idle` with nothing pasted and no
  /// error, losing verbatim text that arrived intact. Raw JSON throughout
  /// because `json(_:)` takes `[String: String]` and so can't express `null`.
  static let rewriteSelectionCases: [(body: Data, expected: String)] = [
    (Data(#"{"text":"um hello","llm_response":"Hello."}"#.utf8), "Hello."),
    (Data(#"{"text":"um hello","llm_response":"Hello.","llm_error":"timeout"}"#.utf8), "Hello."),
    (Data(#"{"text":"hello world","llm_response":null,"llm_error":"timeout"}"#.utf8), "hello world"),
    (Data(#"{"text":"hello world"}"#.utf8), "hello world"),
    (Data(#"{"text":"hello world","llm_response":""}"#.utf8), "hello world"),
    (Data(#"{"text":"hello world","llm_response":"   \n "}"#.utf8), "hello world"),
  ]

  @Test("transcriber returns a usable rewrite, else the verbatim transcript", arguments: rewriteSelectionCases)
  func transcribePicksRewriteOrVerbatim(body: Data, expected: String) async throws {
    let transport = FakeHTTPTransport { _ in (200, body) }
    let result = try await collectTranscript(makeTranscriber(apiKey: "test-key", transport: transport))
    #expect(result == expected)
  }

  @Test("transcriber succeeds with a real context (builds and sends steering fields)")
  func transcribeWithContext() async throws {
    let transport = FakeHTTPTransport { request in
      guard request.url?.path.hasSuffix("/transcribe") == true else { return (404, Data()) }
      return (200, json(["text": "hello world"]))
    }

    // A non-empty context exercises the TranscriptionSteering.build path inside
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
  func transcribeSendsRawKeyNoModelHeaderAndTimeout() async throws {
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

  @Test("config part carries each steering field under its documented wire name")
  func configIncludesSteeringFields() throws {
    let object = try configObject(
      steering: TranscriptionSteering.Fields(
        conversationContext: ["$ git status"], keyterms: ["Blurt", "AssemblyAI"]))
    #expect(object["conversation_context"] as? [String] == ["$ git status"])
    #expect(object["keyterms_prompt"] as? [String] == ["Blurt", "AssemblyAI"])
    #expect(object["sample_rate"] as? Int == 16_000)
    // The capture path is mono by construction; the declared geometry must agree.
    #expect(object["channels"] as? Int == 1)
  }

  @Test("config part never sends a prompt — the managed default is what steers transcription")
  func configNeverSendsPrompt() throws {
    // A custom `config.prompt` replaces the service's managed default *and* its
    // language steering, and the field wants a description of the audio rather
    // than instructions — which is why vocabulary rides in `keyterms_prompt`.
    // Sending no prompt keeps the managed default, so this pins the field's
    // absence for every steering shape.
    let shapes: [TranscriptionSteering.Fields] = [
      .empty,
      TranscriptionSteering.Fields(conversationContext: ["Hi Sam,"], keyterms: ["Blurt"]),
    ]
    for steering in shapes {
      #expect(try configObject(steering: steering).keys.contains("prompt") == false)
    }
  }

  @Test("config part always requests the unsteered default cleanup rewrite")
  func configRequestsDefaultRewrite() throws {
    // `llm` must be present and empty for every utterance: present so the service
    // runs the rewrite at all, empty so the server-owned default cleanup
    // instruction (and its guardrails) applies rather than a client-side copy.
    // Empty also means nothing about the destination app rides here, which is
    // what an earlier `instruction` carried. `isEmpty == true` covers presence
    // too — it is false for a missing `llm`.
    let shapes: [TranscriptionSteering.Fields] = [
      .empty,
      TranscriptionSteering.Fields(conversationContext: ["Hi Sam,"], keyterms: ["Blurt"]),
    ]
    for steering in shapes {
      #expect((try configObject(steering: steering)["llm"] as? [String: Any])?.isEmpty == true)
    }
  }

  @Test("config part omits the context and keyterms fields when they are empty")
  func configOmitsEmptySteeringFields() throws {
    // An empty array is not the same as an absent field: sending
    // `"keyterms_prompt": []` states an empty vocabulary where omission lets the
    // service apply its own handling.
    let object = try configObject(steering: .empty)
    #expect(object.keys.contains("conversation_context") == false)
    #expect(object.keys.contains("keyterms_prompt") == false)
  }

  @Test("the multipart body frames the audio and config parts the dictation API expects")
  func multipartBodyFraming() throws {
    let body = makeTranscriber(apiKey: "test-key")
      .multipartBody(pcm: Data("PCMBYTES".utf8), config: Data(#"{"channels":1}"#.utf8), boundary: "BOUND")
    let text = try #require(String(data: body, encoding: .utf8))

    #expect(text.hasPrefix("--BOUND\r\n"))
    #expect(text.hasSuffix("--BOUND--\r\n"))
    // Field names and the filename are the contract: the server matches on them,
    // so a rename here is a 4xx that no other test would catch.
    #expect(text.contains("Content-Disposition: form-data; name=\"audio\"; filename=\"audio.pcm\"\r\n"))
    #expect(text.contains("Content-Disposition: form-data; name=\"config\"\r\n"))
    // Each part's payload sits after the blank line that ends its headers and runs
    // up to the next boundary — the CRLF placement a hand-built body gets wrong.
    #expect(text.contains("Content-Type: audio/pcm\r\n\r\nPCMBYTES\r\n--BOUND\r\n"))
    #expect(text.contains("Content-Type: application/json\r\n\r\n{\"channels\":1}\r\n--BOUND--\r\n"))
  }

  @Test("arbitrary binary PCM survives the multipart body byte-exact")
  func multipartBodyPreservesBinaryPCM() throws {
    // The audio part is raw S16LE, not text. Any accidental transcoding or stray
    // framing byte would corrupt the upload while the string assertions above still
    // passed, so pin the bytes: every value 0...255, ending exactly at the boundary.
    let pcm = Data((0...255).map { UInt8($0) })
    let body = makeTranscriber(apiKey: "test-key")
      .multipartBody(pcm: pcm, config: Data("{}".utf8), boundary: "B")
    let range = try #require(body.range(of: pcm))
    #expect(body[range.upperBound...].starts(with: Data("\r\n--B\r\n".utf8)))
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

  @Test("HTTP error falls back to the raw body when the shape is unknown")
  func errorMessageFallsBackToRawBody() {
    let body = Data(#"{"unexpected":"shape"}"#.utf8)
    #expect(AssemblyAITranscriber.errorMessage(from: body) == #"{"unexpected":"shape"}"#)
  }

  @Test("HTTP error message is read from the `detail` field too")
  func errorMessageFromDetailField() {
    #expect(AssemblyAITranscriber.errorMessage(from: json(["detail": "audio required"])) == "audio required")
  }

  @Test("HTTP error message field precedence is message > detail")
  func errorMessageFieldPrecedence() {
    // The two documented shapes: `{error_code, message}` for request/audio/server
    // errors and `{detail}` for auth and rate limiting. They shouldn't co-occur,
    // but pin the order so a reorder can't silently change which reaches the user.
    #expect(AssemblyAITranscriber.errorMessage(from: json(["message": "b", "detail": "c"])) == "b")
    #expect(AssemblyAITranscriber.errorMessage(from: json(["detail": "c"])) == "c")
    // An `error` key is in none of the documented responses, so it is no longer
    // consulted — such a body falls through to the raw-body arm rather than
    // yielding the value. (Asserting the behavior, not the serialized bytes.)
    let errorShaped = AssemblyAITranscriber.errorMessage(from: json(["error": "a"]))
    #expect(errorShaped != "a")
    #expect(errorShaped?.contains("error") == true)
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

  /// The encoded `config` part re-parsed as a dictionary — the shape every
  /// config assertion below wants, since `makeConfigData` returns raw JSON.
  /// A part that isn't a JSON object at all fails here rather than turning every
  /// downstream assertion into a silent nil-compare.
  private func configObject(steering: TranscriptionSteering.Fields) throws -> [String: Any] {
    let config = try makeTranscriber(apiKey: "test-key")
      .makeConfigData(sampleRate: 16_000, steering: steering)
    return try #require(JSONSerialization.jsonObject(with: config) as? [String: Any])
  }

  /// Three arbitrary S16LE samples — the raw blob shape `MicCapture.stop()`
  /// hands the transcriber.
  private static let testPCM = Data([0x00, 0x00, 0xCD, 0x0C, 0x33, 0xF3])
}

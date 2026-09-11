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
      guard request.url?.path.hasSuffix("/v1/transcribe/live") == true,
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

  @Test("the response's documented metadata decodes, and a missing field is not a failure")
  func responseMetadataDecodes() async throws {
    // `session_id` is the load-bearing one — the reference asks callers to quote
    // it when reporting a problem — and the timings localize a slow dictation to
    // the STT upstream or the rewrite. They are logged, not returned, so what is
    // asserted here is that a response carrying them still yields the transcript
    // and that a response *missing* them does too: the reference marks
    // `session_id` and `audio_duration_ms` required, and decoding them
    // non-optionally would turn a dropped diagnostic into a failed dictation.
    let full = #"""
      {"text":"hello","llm_response":"Hello.","session_id":"a-b-c",
       "audio_duration_ms":1200,"request_time_ms":840.5,"sync_time_ms":610}
      """#
    for body in [full, #"{"text":"hello","llm_response":"Hello."}"#] {
      let transport = FakeHTTPTransport { _ in (200, Data(body.utf8)) }
      let result = try await collectTranscript(makeTranscriber(apiKey: "k", transport: transport))
      #expect(result == "Hello.")
    }
  }

  @Test("transcriber succeeds with a real context (which builds the prompt)")
  func transcribeWithContext() async throws {
    let transport = FakeHTTPTransport { request in
      guard request.url?.path.hasSuffix("/v1/transcribe/live") == true else { return (404, Data()) }
      return (200, json(["text": "hello world"]))
    }

    // A context with history and prior text exercises the
    // `STTPrompt.text` path inside transcribe() that the nil-context
    // happy path skips, so the request goes out carrying a real
    // `config.stt_prompt`.
    let result = try await collectTranscript(
      makeTranscriber(apiKey: "test-key", transport: transport),
      context: TranscriptionContext(
        appName: "Slack", priorText: "Dear Sam,",
        recentTranscripts: ["Following up on yesterday."]))
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

  @Test("warmUp issues a single GET to the documented /warm endpoint")
  func warmUpPreOpensConnection() async throws {
    let hits = Counter()
    let getHits = Counter()
    let transport = FakeHTTPTransport { request in
      _ = hits.next()
      // The warm-up must be a bare, auth-less GET off the transcribe path —
      // carrying the key would make it count as a transcription — and it must
      // land on `/warm`, the unauthenticated no-op the route publishes for this.
      // It hit the bare host root until 2026-09-11: the same pooled connection,
      // but a request the service never documented answering.
      if request.httpMethod == "GET", request.url?.path == "/warm",
        request.value(forHTTPHeaderField: "Authorization") == nil
      {
        _ = getHits.next()
      }
      return (404, Data())
    }

    // warmUp is fire-and-forget and swallows errors; it should still issue
    // exactly one lightweight GET (no transcribe POST, no auth) to establish
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

  @Test("config part carries the built contextual prompt and the audio geometry")
  func configIncludesSTTPrompt() throws {
    let object = try configObject(prompt: "Previous utterance.\nat the cursor")
    #expect(object["stt_prompt"] as? String == "Previous utterance.\nat the cursor")
    #expect(object["sample_rate"] as? Int == 16_000)
    // The capture path is mono by construction; the declared geometry must agree.
    #expect(object["channels"] as? Int == 1)
  }

  @Test(
    "config part carries our cleanup instruction on every request",
    arguments: ["at the cursor", ""], [true, false])
  func configRequestsRewrite(prompt: String, enhancedTranscripts: Bool) throws {
    // `llm_instruction` must be present on every request under exactly that key
    // — the field name is the contract, and a rename here degrades silently to
    // the service's default cleanup rather than failing anything, so the user
    // would still get *a* rewrite, just not theirs. Sent with and without
    // context, since the two fields are independent.
    //
    // And sent with the enhanced-transcripts switch in **both** positions,
    // which is the change of 2026-09-11: the request no longer varies with that
    // setting at all. `transcript(from:)` applies it to the response instead.
    let object = try configObject(prompt: prompt, enhancedTranscripts: enhancedTranscripts)
    #expect(object["llm_instruction"] as? String == CleanupInstruction.text)
    // Two keys that must never appear. `llm` is the nested block this replaced —
    // both shapes work on the route, so sending both would be silently
    // redundant — *and* it is the route's only off switch, which is exactly what
    // this no longer sends: a null `llm` here would suppress the rewrite the
    // response-side switch now needs in hand.
    #expect(object.keys.contains("llm") == false)
  }

  @Test("config carries the custom style instructions appended to the cleanup instruction")
  func configAppendsCustomStyle() throws {
    let custom = "always write in lowercase"
    let instruction = try #require(
      try configObject(customStyle: custom)["llm_instruction"] as? String)
    // The exact combination rule lives in `CleanupInstructionTests`; what this pins
    // is the wiring — the transcriber's per-request read lands on the request, with
    // the base instruction still leading.
    #expect(instruction == CleanupInstruction.sendable(appending: custom))
  }

  @Test(
    "a blank custom style leaves the cleanup instruction exactly as shipped",
    arguments: [nil, "   \n"])
  func configIgnoresBlankCustomStyle(customStyle: String?) throws {
    let object = try configObject(customStyle: customStyle)
    #expect(object["llm_instruction"] as? String == CleanupInstruction.text)
  }

  @Test(
    "enhanced transcripts off pastes the verbatim transcript, rewrite in hand or not",
    arguments: [
      #"{"text":"um hello","llm_response":"Hello."}"#,
      #"{"text":"um hello","llm_response":null,"llm_error":"timeout"}"#,
      #"{"text":"um hello"}"#,
    ])
  func transcribeReturnsVerbatimWhenDisabled(body: String) async throws {
    // The switch, and the whole of it. Every request asks for the rewrite, so a
    // user with the setting off gets a perfectly good `llm_response` back and it
    // must be ignored — the first row is the one that matters, and it is the row
    // the enabled suite above turns into "Hello.".
    //
    // Until 2026-09-11 this was a *request* switch: the config sent an explicit
    // null `llm`, the route's only off state, because omitting the instruction
    // merely selects the service's own default cleanup. Deciding here costs a
    // rewrite nobody reads (its ~5 s server-side budget, and the billing) and
    // buys one request shape plus a switch that cannot disagree with the
    // response it was applied to.
    let transport = FakeHTTPTransport { _ in (200, Data(body.utf8)) }
    let result = try await collectTranscript(
      makeTranscriber(apiKey: "test-key", transport: transport, enhancedTranscripts: false))
    #expect(result == "um hello")
  }

  @Test("transcriber HTTP error carries the decoded server message")
  func transcribeHTTPErrorMessage() async throws {
    // A documented status carrying a documented shape: 413 with
    // `{error, error_code}`. This asserted a 422 with a `message` key until
    // 2026-09-11, and neither the status nor the field is in the reference —
    // so the test was pinning a response the route does not send.
    let body = json(["error": "audio too long", "error_code": "audio_too_large"])
    let transport = FakeHTTPTransport { _ in (413, body) }

    // The transcriber surfaces its transport error directly; DictationSession is
    // the layer that wraps it in BlurtError.sttFailed before it reaches the UI.
    do {
      _ = try await collectTranscript(makeTranscriber(apiKey: "k", transport: transport))
      Issue.record("expected a throw")
    } catch let AssemblyAIError.http(status, message) {
      #expect(status == 413)
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

  @Test("HTTP error message field precedence is error > detail, and nothing else")
  func errorMessageFieldPrecedence() {
    // The two documented shapes, and only those two: `{error, error_code}` for
    // most failures, `{status, title, detail}` for the ones relayed from the
    // transcription service (invalid key, unsupported format). They shouldn't
    // co-occur, but pin the order so a reorder can't silently change which
    // reaches the user.
    #expect(AssemblyAITranscriber.errorMessage(from: json(["error": "a"])) == "a")
    #expect(AssemblyAITranscriber.errorMessage(from: json(["detail": "c"])) == "c")
    #expect(AssemblyAITranscriber.errorMessage(from: json(["error": "a", "detail": "c"])) == "a")
    // `error` is the field the *common* failures carry, 400 among them — so a
    // config-validation message reaches the user as a sentence instead of as
    // the raw JSON body. It went unread until 2026-09-11.
    #expect(
      AssemblyAITranscriber.errorMessage(
        from: json(["error": "invalid config part: llm: Extra inputs are not permitted"]))
        == "invalid config part: llm: Extra inputs are not permitted")
    // `message` is in *neither* documented shape, so it is deliberately not
    // consulted — such a body falls through to the raw-body arm rather than
    // yielding the value. Same rule that keeps `llm: null` off the request:
    // only the documented contract, in both directions. (Asserting the
    // behavior, not the serialized bytes.)
    let messageShaped = AssemblyAITranscriber.errorMessage(from: json(["message": "b"]))
    #expect(messageShaped != "b")
    #expect(messageShaped?.contains("message") == true)
  }

  @Test("a documented `{error, error_code}` 400 surfaces its sentence, not the body")
  func httpErrorUsesDocumentedErrorField() async throws {
    // End to end, because the decode is only half of it: the status has to
    // arrive carrying the sentence the route sent. This is the shape the
    // reference gives for a 400 — the status a bad config field earns.
    let body = json(["error": "audio part must not be empty", "error_code": "bad_request"])
    let transport = FakeHTTPTransport { _ in (400, body) }
    do {
      _ = try await collectTranscript(makeTranscriber(apiKey: "k", transport: transport))
      Issue.record("expected a throw")
    } catch let AssemblyAIError.http(status, message) {
      #expect(status == 400)
      #expect(message == "audio part must not be empty")
    } catch {
      Issue.record("expected AssemblyAIError.http, got \(error)")
    }
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

  /// The encoded `config` part re-parsed as a dictionary — the shape every
  /// config assertion below wants, since `makeConfigData` returns raw JSON.
  /// A part that isn't a JSON object at all fails here rather than turning every
  /// downstream assertion into a silent nil-compare.
  private func configObject(
    prompt: String = "", enhancedTranscripts: Bool = true, customStyle: String? = nil
  ) throws -> [String: Any] {
    let config = try makeTranscriber(
      apiKey: "test-key", enhancedTranscripts: enhancedTranscripts, customStyle: customStyle
    )
    .makeConfigData(sampleRate: 16_000, sttPrompt: prompt, keytermsPrompt: [])
    return try #require(JSONSerialization.jsonObject(with: config) as? [String: Any])
  }

}

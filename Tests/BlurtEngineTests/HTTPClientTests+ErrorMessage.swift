import Foundation
import Testing

@testable import AssemblyAI
@testable import BlurtAssemblyAI
@testable import BlurtEngine

/// How the transcriber turns a failed response into an error: the documented
/// error shapes, the raw-body fallback, and the descriptions that reach the
/// overlay. Split from `HTTPClientTests.swift` to stay within the lint
/// type-body-length budget; it shares that suite's helpers.
extension HTTPClientTests {
  @Test("transcriber HTTP error carries the decoded server message")
  func transcribeHTTPErrorMessage() async throws {
    // A documented status carrying a documented shape: 503 with
    // `{error, error_code}`. This asserted a 422 with a `message` key until
    // 2026-09-11, and neither the status nor the field is in the reference —
    // so the test was pinning a response the route does not send. It was a 413
    // `audio_too_large` until that became the over-cap fallback's trigger
    // (`LiveCapFallbackTests`), which this fake would have answered twice.
    let body = json(["error": "server at capacity", "error_code": "capacity_exceeded"])
    let failure = try await httpFailure(answering: 503, body: body)
    #expect(failure.status == 503)
    #expect(failure.message == "server at capacity")
  }

  /// The `AssemblyAIError.http` a dictation ends in when the route answers
  /// `status` and `body`; any other outcome fails the test. The transcriber
  /// surfaces its transport error directly; DictationSession is the layer that
  /// wraps it in BlurtError.sttFailed before it reaches the UI.
  private func httpFailure(answering status: Int, body: Data) async throws -> (status: Int, message: String?) {
    let transport = FakeHTTPTransport { _ in (status, body) }
    let error = try await #require(throws: AssemblyAIError.self) {
      try await collectTranscript(makeTranscriber(apiKey: "k", transport: transport))
    }
    guard case let .http(thrown, message) = error else {
      Issue.record("expected AssemblyAIError.http, got \(error)")
      return (0, nil)
    }
    return (thrown, message)
  }

  @Test("HTTP error falls back to the raw body when the shape is unknown")
  func errorMessageFallsBackToRawBody() {
    let body = Data(#"{"unexpected":"shape"}"#.utf8)
    #expect(ErrorResponse.message(in: body) == #"{"unexpected":"shape"}"#)
  }

  @Test("HTTP error message is read from the `detail` field too")
  func errorMessageFromDetailField() {
    #expect(ErrorResponse.message(in: json(["detail": "audio required"])) == "audio required")
  }

  @Test("HTTP error message field precedence is error > detail, and nothing else")
  func errorMessageFieldPrecedence() {
    // The two documented shapes, and only those two: `{error, error_code}` for
    // most failures, `{status, title, detail}` for the ones relayed from the
    // transcription service (invalid key, unsupported format). They shouldn't
    // co-occur, but pin the order so a reorder can't silently change which
    // reaches the user.
    #expect(ErrorResponse.message(in: json(["error": "a"])) == "a")
    #expect(ErrorResponse.message(in: json(["detail": "c"])) == "c")
    #expect(ErrorResponse.message(in: json(["error": "a", "detail": "c"])) == "a")
    // `error` is the field the *common* failures carry, 400 among them — so a
    // config-validation message reaches the user as a sentence instead of as
    // the raw JSON body. It went unread until 2026-09-11.
    #expect(
      ErrorResponse.message(
        in: json(["error": "invalid config part: llm: Extra inputs are not permitted"])
      )
        == "invalid config part: llm: Extra inputs are not permitted")
    // `message` is in *neither* documented shape, so it is deliberately not
    // consulted — such a body falls through to the raw-body arm rather than
    // yielding the value. Same rule that keeps `llm: null` off the request:
    // only the documented contract, in both directions. (Asserting the
    // behavior, not the serialized bytes.)
    let messageShaped = ErrorResponse.message(in: json(["message": "b"]))
    #expect(messageShaped != "b")
    #expect(messageShaped?.contains("message") == true)
  }

  @Test("a documented `{error, error_code}` 400 surfaces its sentence, not the body")
  func httpErrorUsesDocumentedErrorField() async throws {
    // End to end, because the decode is only half of it: the status has to
    // arrive carrying the sentence the route sent. This is the shape the
    // reference gives for a 400 — the status a bad config field earns.
    let body = json(["error": "audio part must not be empty", "error_code": "bad_request"])
    let failure = try await httpFailure(answering: 400, body: body)
    #expect(failure.status == 400)
    #expect(failure.message == "audio part must not be empty")
  }

  @Test("a non-string `detail` (validation array) falls back to the raw body")
  func errorMessageNonStringDetailFallsBack() {
    // FastAPI-style validation errors carry `detail` as an array; that must not
    // decode as the message — the raw body is still more useful than nothing.
    let body = #"{"detail":[{"loc":["config"],"msg":"field required"}]}"#
    #expect(ErrorResponse.message(in: Data(body.utf8)) == body)
  }

  @Test("a raw-body error message is capped at 500 characters")
  func errorMessageRawBodyCapped() {
    // An HTML error page must not flood the overlay/error description.
    let long = String(repeating: "x", count: 600)
    #expect(ErrorResponse.message(in: Data(long.utf8))?.count == 500)
  }

  @Test("HTTP error message is nil only for an empty body")
  func errorMessageNilForEmptyBody() {
    #expect(ErrorResponse.message(in: Data()) == nil)
    #expect(ErrorResponse.message(in: Data("   \n".utf8)) == nil)
  }

  @Test("AssemblyAIError descriptions are non-empty and include the status")
  func assemblyAIErrorDescriptions() {
    #expect(AssemblyAIError.http(status: 500, message: "boom").errorDescription == "AssemblyAI error 500: boom")
    #expect(AssemblyAIError.http(status: 503, message: nil).errorDescription == "AssemblyAI error 503")
    #expect(AssemblyAIError.malformedResponse.errorDescription?.isEmpty == false)
  }
}

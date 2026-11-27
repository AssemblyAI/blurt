import Foundation

/// A dictation API failure body. The reference documents exactly two shapes
/// and says to read both: `{error, error_code}` for most failures (400, 401,
/// 413, 429, 502, 503, 504) and `{status, title, detail}` for the ones relayed
/// from the transcription service — an invalid API key (404, *not* 401) and an
/// unsupported audio format (415). A non-string `detail` (a FastAPI-style
/// validation array) is ignored and the caller falls back to the raw body.
///
/// **`error` is the field the common failures carry**, and reading it is not
/// optional dressing: 400 is the config-validation status, so a wrong field
/// name lands here as
/// `{"error": "invalid config part: <key>: Extra inputs are not permitted",
/// "error_code": "bad_request"}`. This type consulted `message` and `detail`
/// until 2026-09-11, so every one of those fell through to the raw-body arm
/// and surfaced as JSON.
///
/// **Exactly these two keys, because they are the two the reference
/// documents.** `message` was the first key read here and is in neither
/// documented shape; it was dropped rather than kept as a harmless fallback,
/// under the same rule that took `llm: null` off the request — Blurt calls
/// this API only the way the docs describe it, on both directions of the
/// wire. A body carrying some third spelling now reaches the user through the
/// raw-body arm below, which is the honest outcome: unrecognized, not silently
/// guessed at.
///
/// `error_code` is the `{error, error_code}` shape's machine-readable half, and
/// it is read for exactly one decision: `413` with `audio_too_large` is the
/// streaming route refusing a recording past its 120 s cap, which Blurt answers
/// by sending the whole recording to `/v1/transcribe` instead
/// (`DictationClient`'s over-cap fallback). A status alone can't make that
/// call — the route documents `413` for its size cap too, under the same code,
/// and any other `413` must surface as it always has.
struct ErrorResponse: Decodable, Sendable {
  enum CodingKeys: String, CodingKey {
    case error, detail
    case errorCode = "error_code"
  }

  let message: String?
  /// The documented machine-readable code (`bad_request`, `audio_too_large`,
  /// `capacity_exceeded`, `upstream_error`, `upstream_timeout`), or nil for the
  /// `{status, title, detail}` shape, which carries none.
  let errorCode: String?

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    // `try? decode` already yields `String?` for a key that is missing, null,
    // or the wrong type — `decodeIfPresent` would return `String??` here and
    // need flattening back down.
    func string(_ key: CodingKeys) -> String? {
      try? container.decode(String.self, forKey: key)
    }
    message = string(.error) ?? string(.detail)
    errorCode = string(.errorCode)
  }
}

extension ErrorResponse {
  /// `error`, then `detail`, from a body in one of the two documented shapes;
  /// nil for anything else. What the `/v2` async client reads, since its text
  /// is shown to the user as is.
  static func documentedMessage(in data: Data) -> String? {
    (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.message
  }

  /// Best human-readable explanation for a non-2xx response: `error`, then
  /// `detail` (the two documented shapes, above), then the raw body text,
  /// trimmed and capped. The dictation client reads its failures through it.
  ///
  /// The raw-body arm is deliberately kept. It is not compatibility with an old
  /// API shape — it is what turns a response the API never promised (a proxy's HTML
  /// 502, a captive-portal page) into something diagnosable instead of a bare
  /// status code. Returns nil only for an empty body.
  static func message(in data: Data) -> String? {
    if let message = documentedMessage(in: data) {
      return message
    }
    guard let raw = String(bytes: data, encoding: .utf8)?.trimmedNonEmpty() else {
      return nil
    }
    return String(raw.prefix(500))
  }
}

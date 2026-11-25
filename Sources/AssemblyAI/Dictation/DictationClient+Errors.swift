import Foundation

// How a failed response becomes an `AssemblyAIError`, out of the transport's
// file for the lint file-length budget.
extension DictationClient {
  /// Throws `AssemblyAIError.http` for a non-2xx response, carrying the
  /// service's own sentence. Shared by both requests, so a failed fallback
  /// surfaces *its* error in exactly the shape a failed live request does.
  static func requireSuccess(_ response: URLResponse, body data: Data) throws {
    guard let http = response as? HTTPURLResponse else {
      return
    }
    guard (200..<300).contains(http.statusCode) else {
      throw AssemblyAIError.http(status: http.statusCode, message: errorMessage(from: data))
    }
  }

  /// Best human-readable explanation for a non-2xx response: `error`, then
  /// `detail` (the two documented shapes — see `ErrorResponse`, which is also
  /// where the dropped `message` key is accounted for), then the raw body text,
  /// trimmed and capped.
  ///
  /// The raw-body arm is deliberately kept. It is not compatibility with an old
  /// API shape — it is what turns a response the API never promised (a proxy's HTML
  /// 502, a captive-portal page) into something diagnosable instead of a bare
  /// status code. Returns nil only for an empty body.
  static func errorMessage(from data: Data) -> String? {
    if let parsed = try? JSONDecoder().decode(ErrorResponse.self, from: data),
      let message = parsed.message
    {
      return message
    }
    guard let raw = String(bytes: data, encoding: .utf8)?.trimmedNonEmpty() else {
      return nil
    }
    return String(raw.prefix(500))
  }
}

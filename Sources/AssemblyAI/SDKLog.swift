import Foundation
import os

/// The SDK's own log, apart from any app's: transport faults, and the dictation
/// client's latency lines unless the caller hands it a logger of its own.
enum SDKLog {
  static let transport = Logger(subsystem: "com.assemblyai.sdk", category: "Transport")
  /// The dictation round trip's latency lines: connect vs inference, the
  /// server's own timings and `session_id`.
  static let dictation = Logger(subsystem: "com.assemblyai.sdk", category: "Dictation")
  /// Refused or failed OAuth calls: the route, the status and the server's own
  /// error fields. Never a token.
  static let oauth = Logger(subsystem: "com.assemblyai.sdk", category: "OAuth")
}

extension URL {
  /// A URL from a literal known to be valid; the SDK's own copy of BlurtEngine's
  /// helper, so neither module reaches into the other.
  init(literal: StaticString) {
    guard let url = URL(string: "\(literal)") else {
      preconditionFailure("Invalid URL literal: \(literal)")
    }
    self = url
  }
}

extension URLRequest {
  /// A JSON `POST` to `url`, authorized as `authorize(apiKey:userAgent:)` does:
  /// the shape the TTS, LLM Gateway and async transcript routes share. Keys are sorted so a body is the same bytes twice.
  static func jsonPost(
    to url: URL,
    apiKey: String,
    userAgent: String?,
    timeout: TimeInterval,
    body: some Encodable
  ) throws -> URLRequest {
    var request = URLRequest(url: url, timeoutInterval: timeout)
    request.httpMethod = "POST"
    request.authorize(apiKey: apiKey, userAgent: userAgent)
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    request.httpBody = try encoder.encode(body)
    return request
  }

  /// Authorizes this request the way every AssemblyAI route takes it: the raw
  /// key in `Authorization` (no "Bearer"), and the calling app's agent when it
  /// names one. The SDK's one spelling of it.
  mutating func authorize(apiKey: String, userAgent: String?) {
    setValue(apiKey, forHTTPHeaderField: "Authorization")
    setUserAgent(userAgent)
  }

  /// Names the calling app in `User-Agent` when it names one — every SDK
  /// request, authorized by key or not, so none is the one the service can't
  /// attribute.
  mutating func setUserAgent(_ userAgent: String?) {
    if let userAgent {
      setValue(userAgent, forHTTPHeaderField: "User-Agent")
    }
  }
}

extension String {
  /// The string trimmed of surrounding whitespace, or nil when nothing is left.
  func trimmedNonEmpty() -> String? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

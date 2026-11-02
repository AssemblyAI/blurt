import Foundation
import os

/// The SDK's own log, apart from any app's. Only transport faults are logged.
enum SDKLog {
  static let transport = Logger(subsystem: "com.assemblyai.sdk", category: "Transport")
  /// Refused or failed OAuth calls: the route, the status and the server's own
  /// error fields. Never a token.
  static let oauth = Logger(subsystem: "com.assemblyai.sdk", category: "OAuth")
}

extension URL {
  /// A URL from a literal known to be valid; the SDK's own copy of BlurtEngine's
  /// helper, so neither module reaches into the other. `@usableFromInline` for
  /// the reason the engine's copy gives: public inits' default arguments use it.
  @usableFromInline
  init(literal: StaticString) {
    guard let url = URL(string: "\(literal)") else {
      preconditionFailure("Invalid URL literal: \(literal)")
    }
    self = url
  }
}

extension URLRequest {
  /// Authorizes this request the way every AssemblyAI route takes it: the raw
  /// key in `Authorization` (no "Bearer"), and the calling app's agent when it
  /// names one. The SDK's one spelling of it.
  mutating func authorize(apiKey: String, userAgent: String?) {
    setValue(apiKey, forHTTPHeaderField: "Authorization")
    if let userAgent { setValue(userAgent, forHTTPHeaderField: "User-Agent") }
  }
}

extension String {
  /// The string trimmed of surrounding whitespace, or nil when nothing is left.
  func trimmedNonEmpty() -> String? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

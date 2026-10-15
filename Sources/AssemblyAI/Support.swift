import Foundation
import os

/// The SDK's own log, apart from any app's. Only transport faults are logged.
enum SDKLog {
  static let transport = Logger(subsystem: "com.assemblyai.sdk", category: "Transport")
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

extension String {
  /// The string trimmed of surrounding whitespace, or nil when nothing is left.
  func trimmedNonEmpty() -> String? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

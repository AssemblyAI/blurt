public protocol TextNormalizer: Sendable {
  func normalize(rawTranscript: String, vocabulary: [String]) async throws -> String
}

public enum NormalizationFallback {
  public static func short(
    normalized: String?, assemblyClean: String?, raw: String
  ) -> String {
    normalized.trimmedNonEmpty()
      ?? assemblyClean.trimmedNonEmpty()
      ?? raw
  }

  public static func long(normalized: String?, raw: String) -> String {
    normalized.trimmedNonEmpty() ?? raw
  }
}

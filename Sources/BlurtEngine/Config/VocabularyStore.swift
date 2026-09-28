import Foundation

public struct VocabularyStore {
  public static let initialTerms = [
    "API", "SDK", "REST", "GraphQL", "WebSocket", "webhook", "endpoint", "frontend",
    "backend", "database", "OpenAI", "OpenRouter", "AssemblyAI", "Gemini", "Claude", "GPT",
    "Codex", "Cursor", "GitHub", "GitLab", "MCP", "LLM", "STT", "TTS", "JSON", "YAML",
    "HTTP", "HTTPS", "OAuth", "JWT", "SSH", "CLI", "Docker", "Kubernetes", "PostgreSQL",
    "Postgres", "SQLite", "Redis", "Supabase", "Firebase", "Vercel", "Cloudflare", "AWS",
    "Swift", "SwiftUI", "AppKit", "Xcode", "Python", "FastAPI", "JavaScript", "TypeScript",
    "Node.js", "React", "Next.js", "Vue", "Tailwind", "npm", "pnpm", "Bun",
  ]

  public static var defaultsKey: String { DefaultsKey.vocabulary.key }
  private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  public var terms: [String] {
    guard let stored = defaults.stringArray(forKey: Self.defaultsKey) else {
      // Keep the existing comma-separated Settings editor useful during the
      // migration. Once the new vocabulary has been saved it becomes the sole
      // editable source, including intentional removals from the starter list.
      return Self.deduplicated(Self.initialTerms + KeyTermsStore(defaults: defaults).terms)
    }
    return Self.deduplicated(stored)
  }

  public func save(_ terms: [String]) {
    defaults.set(Self.deduplicated(terms), forKey: Self.defaultsKey)
  }

  public func add(_ term: String) {
    save(terms + [term])
  }

  public func remove(_ term: String) {
    let key = term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    save(terms.filter { $0.lowercased() != key })
  }

  public static func deduplicated(_ terms: [String]) -> [String] {
    var seen = Set<String>()
    return terms.compactMap { value in
      guard let term = value.trimmedNonEmpty() else { return nil }
      guard seen.insert(term.lowercased()).inserted else { return nil }
      return term
    }
  }
}

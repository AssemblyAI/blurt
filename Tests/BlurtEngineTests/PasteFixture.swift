#if os(macOS)
  import Foundation
  import Testing

  @testable import BlurtEngine

  /// One recorded paste situation.
  struct PasteFixture: Codable, Equatable {
    static let url = TestFixtures.url("Tests/PasteFixtures/pastes.json")

    /// Every key a fixture is written with, read off one with every field set.
    static var keys: Set<String> {
      let full = Self(
        name: "",
        app: "",
        pastes: true,
        facts: PasteFacts(focused: true, role: "", subrole: "", bundleID: "")
      )
      let object = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(full))) as? [String: Any] ?? [:]
      return Set(object.keys).union((object["facts"] as? [String: Any] ?? [:]).keys)
    }

    let name: String
    /// The app opened for it, as `open_app` names it.
    let app: String
    /// Whether a dictation there should be pasted (else left on the clipboard).
    let pastes: Bool
    let facts: PasteFacts

    static func loadAll() throws -> [Self] {
      try JSONDecoder().decode([Self].self, from: Data(contentsOf: url))
    }

    static func save(_ fixtures: [Self]) throws {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true
      )
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(fixtures).write(to: url)
    }
  }
#endif

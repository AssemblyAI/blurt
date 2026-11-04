import Foundation

/// The checked-in fixture sets — recorded screens, paste situations, the
/// planner eval's corpus — found from one place, and held to one privacy
/// rule: a fixture carries structure, never anything that reads as a person's.
enum TestFixtures {
  /// A path relative to the repository root.
  static func url(_ relativeToRepo: String) -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent(relativeToRepo)
  }

  /// Shapes of personal data: an email address, a home-folder path, a phone
  /// number. No fixture may hold one.
  static let personalShapes = [
    #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, #"/Users/"#, #"~/"#, #"\b\d{3}[-. ]\d{3}[-. ]\d{4}\b"#,
  ]

  /// A web address — personal in a recording or a paste fixture, which hold
  /// no page content, but the subject of some planner eval cases.
  static let webShapes = [#"https?://"#, #"www\."#]

  /// Every problem with a fixture's raw JSON: a string shaped like one of
  /// `shapes`, or a key — at any depth — outside `allowedKeys`, so nothing
  /// rides in under a field its decoder would silently ignore.
  static func audit(_ raw: String, shapes: [String], allowedKeys: Set<String>) throws -> [String] {
    var problems = shapes.filter { raw.range(of: $0, options: .regularExpression) != nil }
      .map { "something shaped like \($0)" }
    let extra = keys(in: try JSONSerialization.jsonObject(with: Data(raw.utf8))).subtracting(allowedKeys)
    if !extra.isEmpty { problems.append("unexpected keys \(extra.sorted())") }
    return problems
  }

  private static func keys(in object: Any) -> Set<String> {
    if let dictionary = object as? [String: Any] {
      return dictionary.values.reduce(into: Set(dictionary.keys)) { $0.formUnion(keys(in: $1)) }
    }
    if let array = object as? [Any] { return array.reduce(into: []) { $0.formUnion(keys(in: $1)) } }
    return []
  }
}

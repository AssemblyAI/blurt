/// A dotted numeric version (`major.minor.patch…`) parsed for comparison —
/// used to decide whether a GitHub release is newer than the running app.
/// Accepts an optional leading `v` (GitHub tags are `v0.1.30`; the bundle's
/// `CFBundleShortVersionString` is the bare `0.1.30`). Comparison is
/// component-wise with missing trailing components treated as zero, so
/// `1.2 == 1.2.0`.
public struct SemanticVersion: Sendable, Equatable, Comparable, CustomStringConvertible {
  /// The `v`-stripped source string, kept for display in the UI.
  public let description: String
  private let components: [Int]

  /// Parses `"0.1.30"` / `"v0.1.30"`. Returns nil when the string is empty or
  /// any dot-separated component isn't a non-negative integer, so a malformed
  /// tag reads as "can't determine" rather than crashing.
  public init?(_ string: String) {
    var text = string
    if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
    let parts = text.split(separator: ".", omittingEmptySubsequences: false)
    guard !parts.isEmpty else { return nil }
    var parsed: [Int] = []
    for part in parts {
      guard let value = Int(part), value >= 0 else { return nil }
      parsed.append(value)
    }
    description = text
    components = parsed
  }

  public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
    lhs.ordering(vs: rhs) < 0
  }

  public static func == (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
    lhs.ordering(vs: rhs) == 0
  }

  /// Component-wise comparison to `other`: negative if `self` sorts first, 0 if
  /// equal, positive otherwise. Missing trailing components count as 0, so
  /// `1.2` orders equal to `1.2.0`. The single source both `<` and `==` derive
  /// from.
  private func ordering(vs other: SemanticVersion) -> Int {
    let count = max(components.count, other.components.count)
    for index in 0..<count {
      let (mine, theirs) = (component(at: index), other.component(at: index))
      if mine != theirs { return mine < theirs ? -1 : 1 }
    }
    return 0
  }

  /// The component at `index`, or 0 past the end — so `1.2` compares as `1.2.0`.
  private func component(at index: Int) -> Int {
    index < components.count ? components[index] : 0
  }
}

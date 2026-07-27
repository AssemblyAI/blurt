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
    let (left, right) = alignedComponents(lhs, rhs)
    return left.lexicographicallyPrecedes(right)
  }

  public static func == (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
    let (left, right) = alignedComponents(lhs, rhs)
    return left == right
  }

  /// Both versions' components zero-extended to a common length, so `1.2` and
  /// `1.2.0` compare as the identical `[1, 2, 0]`. The single basis both `<` and
  /// `==` order on: element-wise array comparison, rather than a hand-rolled
  /// three-way `Int` sentinel the two operators then had to interpret.
  private static func alignedComponents(
    _ lhs: SemanticVersion, _ rhs: SemanticVersion
  ) -> (left: [Int], right: [Int]) {
    let width = max(lhs.components.count, rhs.components.count)
    return (lhs.padded(to: width), rhs.padded(to: width))
  }

  /// This version's components zero-extended to `width`.
  private func padded(to width: Int) -> [Int] {
    components + Array(repeating: 0, count: max(0, width - components.count))
  }
}

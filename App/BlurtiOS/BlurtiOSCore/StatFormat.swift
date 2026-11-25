import Foundation

/// The stats card's renderings. Counts stay short; time saved is shown in full
/// ("1 hr 25 min 45 sec"), because watching every second add up is the point.
package nonisolated enum StatFormat {
  /// A count, compact past four digits: `9,999`, then `12K`.
  package static func count(_ value: Int) -> String {
    value < 10_000 ? value.formatted() : value.formatted(.number.notation(.compactName))
  }

  /// A duration as number-and-unit parts, largest first, skipping zero parts:
  /// `[("1", "hr"), ("25", "min"), ("45", "sec")]`. Under a second is `0 sec`.
  package static func durationParts(_ duration: Duration) -> [(value: String, unit: String)] {
    var remaining = Int(duration.components.seconds)
    guard remaining > 0 else {
      return [("0", "sec")]
    }
    var parts: [(String, String)] = []
    for (unit, size) in [("day", 86_400), ("hr", 3_600), ("min", 60), ("sec", 1)] {
      let amount = remaining / size
      remaining %= size
      if amount > 0 { parts.append((amount.formatted(), unit)) }
    }
    return parts
  }
}

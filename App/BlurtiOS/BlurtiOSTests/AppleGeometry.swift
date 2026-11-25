import Foundation
import KeyboardKit
import Testing

/// One measured profile (`Design/apple-geometry-*.json`), bundled with the
/// tests: its width and the `cap` numbers scripts/apple-geometry.sh read off
/// the iPhone's own keyboard. The keys are KeyboardKit's now, so no token
/// answers to these numbers; the files stay as the oracle the parity probe
/// measures Apple's keyboard and ours against (`scripts/keyboard-parity.sh`).
struct AppleGeometry {
  private final class BundleToken {}

  let width: CGFloat
  let cap: [String: Double]
  let unmeasured: Bool

  static func load(_ file: String) throws -> Self {
    let url = try #require(Bundle(for: BundleToken.self).url(forResource: file, withExtension: "json"))
    let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    let rawCap = try #require(json["cap"] as? [String: Any])
    var numbers: [String: Double] = [:]
    for (key, value) in rawCap {
      if let number = value as? Double { numbers[key] = number }
    }
    let rawWidth = try #require(json["width"] as? Double)
    return Self(
      width: CGFloat(rawWidth), cap: numbers, unmeasured: (json["unmeasured"] as? Bool) ?? false
    )
  }
}

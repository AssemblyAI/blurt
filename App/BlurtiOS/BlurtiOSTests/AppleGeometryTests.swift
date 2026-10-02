import BlurtDesign
import Foundation
import Testing

@testable import BlurtiOS

/// The key tokens against what scripts/apple-geometry.sh read off the
/// iPhone's own keyboard (`Design/apple-geometry.json`): the design's numbers
/// are Apple's, measured, and a change to either side has to be a decision.
/// Tolerances are the measurement's: pixels come in thirds of a point, the
/// surface's edge is anti-aliased, the radius is a fit.
@Suite("Apple's keyboard geometry")
struct AppleGeometryTests {
  private final class BundleToken {}

  private static func measured() throws -> [String: Double] {
    let url = try #require(Bundle(for: BundleToken.self).url(forResource: "apple-geometry", withExtension: "json"))
    let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    let cap = try #require(json["cap"] as? [String: Any])
    var numbers: [String: Double] = [:]
    for (key, value) in cap {
      if let number = value as? NSNumber { numbers[key] = number.doubleValue }
    }
    return numbers
  }

  private static func value(_ numbers: [String: Double], _ key: String) throws -> Double {
    try #require(numbers[key], "apple-geometry.json has no cap.\(key)")
  }

  @Test("the keys are the iPhone's: width, height, gaps, margins, radius")
  func keys() throws {
    let cap = try Self.measured()
    let metrics = DesignTokens.Metrics.self
    #expect(abs(try Self.value(cap, "letter") - metrics.keyLetterWidth402) < 0.05)
    #expect(try Self.value(cap, "height") == metrics.keyHeight)
    #expect(try Self.value(cap, "gap") == metrics.keyGap)
    #expect(try Self.value(cap, "rowGap") == metrics.rowGap)
    #expect(abs(try Self.value(cap, "marginSide") - metrics.marginSide) < 0.2)
    #expect(abs(try Self.value(cap, "radius") - metrics.keyRadius) < 0.5)
    #expect(abs(try Self.value(cap, "side") - metrics.keySideWidth402) < 0.1)
    #expect(abs(try Self.value(cap, "sideGap") - metrics.keySideGap) < 0.05)
    #expect(abs(try Self.value(cap, "abc") - metrics.keyAbcWidth402) < 0.05)
    #expect(abs(try Self.value(cap, "return") - metrics.keyReturnWidth402) < 0.5)
    #expect(abs(try Self.value(cap, "space") - metrics.keySpaceWidth402) < 0.5)
  }

  @Test("the rows are the iPhone's: the band above the keys, the margin under them, the whole height")
  func rows() throws {
    let cap = try Self.measured()
    let metrics = DesignTokens.Metrics.self
    #expect(abs(try Self.value(cap, "topBand") - (metrics.marginVertical + metrics.voicebarHeight)) < 1)
    #expect(try Self.value(cap, "bottomMargin") == metrics.marginBottomKeys)
    #expect(abs(try Self.value(cap, "keyboardHeight") - metrics.layoutFull) < 1)
  }

  @Test("the geometry reproduces the measured row at the reference width")
  func arithmetic() throws {
    let cap = try Self.measured()
    let width = DesignTokens.Metrics.keyReferenceWidth
    let geometry = KeyGeometry(width: width)
    #expect(abs(geometry.letterWidth - (try Self.value(cap, "letter"))) < 0.05)
    #expect(abs(geometry.sideWidth - (try Self.value(cap, "side"))) < 0.1)
    #expect(abs(geometry.returnWidth - (try Self.value(cap, "return"))) < 0.5)
    // The rows add up to the width, margins included.
    let margin = DesignTokens.Metrics.marginSide
    #expect(abs(10 * geometry.letterWidth + 9 * geometry.gap + 2 * margin - width) < 0.001)
    #expect(
      abs(
        2 * geometry.sideWidth + 2 * geometry.sideGap + 7 * geometry.letterWidth + 6 * geometry.gap + 2 * margin - width
      )
        < 0.001)
    #expect(
      abs(
        2 * geometry.abcWidth + geometry.spaceWidth(globe: true) + geometry.returnWidth + 3 * geometry.gap + 2 * margin
          - width) < 0.001)
  }
}

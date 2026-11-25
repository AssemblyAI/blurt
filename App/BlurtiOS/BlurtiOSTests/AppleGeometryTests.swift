import CoreGraphics
import Testing

/// The measured files against what they claim: each parses at the width its
/// name says, with the row's numbers; the glass file was measured on a phone,
/// the classic ones say they were not (no iOS 18 runtime installs under
/// Xcode 27), so a fallback number is never mistaken for Apple's.
@Suite("Apple's keyboard geometry")
struct AppleGeometryTests {
  /// Each file beside whether a phone measured it; the width is the name's.
  nonisolated static let files: [(file: String, measured: Bool)] = [
    ("apple-geometry-glass-402", true), ("apple-geometry-classic-390", false), ("apple-geometry-classic-375", false),
  ]

  /// What scripts/apple-geometry.sh reads off every row.
  nonisolated static let caps = [
    "letter", "height", "gap", "rowGap", "marginSide", "radius", "side", "sideGap", "abc", "return", "space",
    "topBand", "bottomMargin", "keyboardHeight",
  ]

  @Test("each file parses at the width its name says, with every number the probe reads", arguments: files)
  func parses(file: String, measured _: Bool) throws {
    let geometry = try AppleGeometry.load(file)
    let width = try #require(file.split(separator: "-").last.flatMap { Int($0) })
    #expect(geometry.width == CGFloat(width))
    for cap in Self.caps {
      #expect((geometry.cap[cap] ?? 0) > 0, "\(file): no cap.\(cap)")
    }
  }

  @Test("the glass file is measured; the classic ones say they are not", arguments: files)
  func provenance(file: String, measured: Bool) throws {
    let geometry = try AppleGeometry.load(file)
    #expect(geometry.unmeasured == !measured, "\(file): \(measured ? "lost its measurement" : "measured — say so")")
  }
}

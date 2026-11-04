import BlurtDesign
import BlurtiOSCore
import Foundation
import Testing

@testable import BlurtiOS

/// The profile tokens against what scripts/apple-geometry.sh read off the
/// iPhone's own keyboard, one JSON per profile (`Design/apple-geometry-*.json`):
/// the design's numbers are Apple's, measured, and a change to either side
/// has to be a decision. Tolerances are the measurement's: pixels come in
/// thirds (or halves) of a point, the surface's edge is anti-aliased, the
/// radius is a fit. The classic files carry `unmeasured: true` until an
/// iOS 18.6 simulator can run the probe; the tokens equal them by
/// construction then, and the test says so.
@Suite("Apple's keyboard geometry")
struct AppleGeometryTests {
  /// Each JSON with the generation it measures and its width.
  nonisolated static let profiles: [(file: String, generation: KeyboardProfile.Generation)] = [
    ("apple-geometry-glass-402", .glass), ("apple-geometry-classic-390", .classic),
    ("apple-geometry-classic-375", .classic),
  ]

  private static func value(_ geometry: AppleGeometry, _ key: String) throws -> Double {
    try #require(geometry.cap[key], "no cap.\(key)")
  }

  @Test("the keys are the iPhone's: width, height, gaps, margins, radius", arguments: profiles)
  func keys(file: String, generation: KeyboardProfile.Generation) throws {
    let measured = try AppleGeometry.load(file)
    let profile = KeyboardProfile(generation: generation, width: measured.width, hasGlobe: measured.width == 375)
    let geometry = KeyGeometry(width: measured.width, profile: profile)
    #expect(abs(try Self.value(measured, "letter") - geometry.letterWidth) < 0.05)
    #expect(try Self.value(measured, "height") == profile.keyHeight)
    #expect(try Self.value(measured, "gap") == profile.keyGap)
    #expect(try Self.value(measured, "rowGap") == profile.rowGap)
    #expect(abs(try Self.value(measured, "marginSide") - profile.marginSide) < 0.2)
    #expect(abs(try Self.value(measured, "radius") - profile.keyRadius) < 0.5)
    #expect(abs(try Self.value(measured, "side") - geometry.sideWidth) < 0.1)
    #expect(abs(try Self.value(measured, "sideGap") - geometry.sideGap) < 0.05)
    #expect(abs(try Self.value(measured, "abc") - geometry.abcWidth) < 0.05)
    #expect(abs(try Self.value(measured, "return") - geometry.returnWidth) < 0.5)
    // Apple's own bottom row carries the globe whatever the phone (123 ·
    // globe · space · return), so the measured space is the one beside it.
    #expect(abs(try Self.value(measured, "space") - geometry.spaceWidth(globe: true)) < 0.5)
  }

  @Test(
    "the rows are the iPhone's: the band above the keys, the margin under them, the whole height", arguments: profiles)
  func rows(file: String, generation: KeyboardProfile.Generation) throws {
    let measured = try AppleGeometry.load(file)
    let profile = KeyboardProfile(generation: generation, width: measured.width, hasGlobe: measured.width == 375)
    #expect(abs(try Self.value(measured, "topBand") - profile.topBand) < 1)
    #expect(try Self.value(measured, "bottomMargin") == profile.bottomInset)
    #expect(abs(try Self.value(measured, "keyboardHeight") - KeyboardLayout.full.height(profile: profile)) < 1)
  }

  @Test("the @402 tokens are the glass measurement, and the geometry reproduces the measured row at that width")
  func glassReference() throws {
    let measured = try AppleGeometry.load("apple-geometry-glass-402")
    let metrics = DesignTokens.Metrics.self
    #expect(measured.width == metrics.keyReferenceWidth)
    #expect(!measured.unmeasured)
    #expect(abs(try Self.value(measured, "letter") - metrics.keyLetterWidth402) < 0.05)
    #expect(abs(try Self.value(measured, "side") - metrics.keySideWidth402) < 0.1)
    #expect(abs(try Self.value(measured, "abc") - metrics.keyAbcWidth402) < 0.05)
    #expect(abs(try Self.value(measured, "return") - metrics.keyReturnWidth402) < 0.5)
    #expect(abs(try Self.value(measured, "space") - metrics.keySpaceWidth402) < 0.5)
    let profile = KeyboardProfile(generation: .glass, width: measured.width, hasGlobe: true)
    let geometry = KeyGeometry(width: measured.width, profile: profile)
    #expect(abs(geometry.letterWidth - (try Self.value(measured, "letter"))) < 0.05)
    #expect(abs(geometry.sideWidth - (try Self.value(measured, "side"))) < 0.1)
    #expect(abs(geometry.returnWidth - (try Self.value(measured, "return"))) < 0.5)
  }

  @Test("the classic files say whether they were measured, so a fallback number is never mistaken for Apple's")
  func classicProvenance() throws {
    for (file, generation) in Self.profiles where generation == .classic {
      let measured = try AppleGeometry.load(file)
      // Unmeasured today (no iOS 18 runtime installs under Xcode 27); once
      // scripts/apple-geometry.sh --profile classic-… has run, the flag goes
      // and the tokens answer to the measurement above.
      #expect(measured.unmeasured, "\(file): measured — update the classic/* tokens' use notes")
    }
  }
}

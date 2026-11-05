import BlurtDesign
import BlurtiOSCore
import CoreFoundation
import Foundation
import Testing

@testable import BlurtiOS

/// The keyboard's profile (`KeyboardProfile`): which generation a phone
/// gets, its size class, and every number at the widths the iPhone comes in
/// — 375 (SE), 390 (13 / 16e), 393 (15 / 16), 402 (18 Pro), 430 (14 Pro
/// Max) — on both generations: each row adds up to the width, and the
/// widths with a measured profile (`Design/apple-geometry-*.json`) match it.
@Suite("Keyboard profile")
struct KeyboardProfileTests {
  nonisolated private static let widths: [CGFloat] = [375, 390, 393, 402, 430]
  nonisolated private static let generations: [KeyboardProfile.Generation] = [.classic, .glass]

  private static func profile(_ generation: KeyboardProfile.Generation, width: CGFloat) -> KeyboardProfile {
    KeyboardProfile(generation: generation, width: width, hasGlobe: width == 375)
  }

  @Test("glass only on iOS 26 and later with the host's container detected; classic everywhere else")
  func generation() {
    let glass = KeyboardProfile.glassOSMajor
    #expect(KeyboardProfile.generation(osMajor: glass - 8, hostContainerInset: 16) == .classic)
    #expect(KeyboardProfile.generation(osMajor: glass - 1, hostContainerInset: nil) == .classic)
    #expect(KeyboardProfile.generation(osMajor: glass, hostContainerInset: 16) == .glass)
    #expect(KeyboardProfile.generation(osMajor: glass + 1, hostContainerInset: 16) == .glass)
    // An un-adopted iOS 26 host leaves no inset around the keyboard.
    #expect(KeyboardProfile.generation(osMajor: glass, hostContainerInset: 0) == .classic)
    #expect(
      KeyboardProfile.generation(osMajor: glass, hostContainerInset: DesignTokens.Metrics.containerInsetMin - 1)
        == .classic)
    #expect(
      KeyboardProfile.generation(osMajor: glass, hostContainerInset: DesignTokens.Metrics.containerInsetMin) == .glass)
    // Not read yet: the container is taken as there on an OS that has one.
    #expect(KeyboardProfile.generation(osMajor: glass, hostContainerInset: nil) == .glass)
    // The resolver reads this process's OS; the stand-in's generation is the same read.
    let resolved = KeyboardProfile.resolve(width: 390, hasGlobe: false, hostContainerInset: nil)
    #expect(resolved.generation == KeyboardProfile.standInGeneration)
    #expect(resolved == KeyboardProfile.standIn(width: 390, hasGlobe: false))
    #expect(KeyboardProfile.osMajor > 0)
  }

  @Test("the size class: compact up to the Pro, large from the Plus and Max")
  func sizeClass() {
    for width in Self.widths {
      let profile = Self.profile(.classic, width: width)
      #expect(profile.sizeClass == (width >= DesignTokens.Metrics.sizeLargeMinWidth ? .large : .compact), "\(width)")
      #expect(profile.width == width)
    }
    #expect(Self.profile(.glass, width: 402).sizeClass == .compact)
    #expect(Self.profile(.glass, width: 414).sizeClass == .large)
  }

  @Test("the generation's numbers: the container, the painted surface, the band above the keys")
  func numbers() {
    let metrics = DesignTokens.Metrics.self
    let classic = Self.profile(.classic, width: 390)
    #expect(!classic.inContainer && classic.paintsSurface)
    #expect(classic.marginSide == metrics.classicMarginSide && classic.edgeInset == classic.marginSide)
    #expect(classic.keyGap == metrics.classicKeyGap && classic.sideGap == metrics.classicSideGap)
    #expect(classic.keyHeight == metrics.classicKeyHeight && classic.rowGap == metrics.classicRowGap)
    #expect(classic.marginTop == metrics.classicMarginTop && classic.bottomInset == metrics.classicBottomInset)
    #expect(classic.keyRadius == metrics.classicKeyRadius)
    #expect(classic.topBand == metrics.classicMarginTop + metrics.voicebarHeight)
    // Classic lays the row out as W/10 cells: the margin is half a gap.
    #expect(2 * classic.marginSide == classic.keyGap)
    let glass = Self.profile(.glass, width: 402)
    #expect(glass.inContainer && glass.paintsSurface == (metrics.surfacePaint > 0))
    #expect(glass.marginSide == metrics.marginSide && glass.keyGap == metrics.keyGap)
    #expect(glass.sideGap == metrics.keySideGap && glass.keyHeight == metrics.keyHeight)
    #expect(glass.rowGap == metrics.rowGap && glass.marginTop == metrics.marginVertical)
    #expect(glass.bottomInset == metrics.marginBottomKeys && glass.keyRadius == metrics.keyRadius)
    #expect(glass.topBand == metrics.marginVertical + metrics.voicebarHeight)
  }

  @Test(
    "every row adds up to the keyboard's width within 0.5 pt, at every width, on both generations",
    arguments: generations, widths)
  func rowsAddUp(generation: KeyboardProfile.Generation, width: CGFloat) {
    let profile = Self.profile(generation, width: width)
    let geometry = KeyGeometry(width: width, profile: profile)
    let margins = 2 * profile.marginSide
    let letters = 10 * geometry.letterWidth + 9 * geometry.gap + margins
    let third = 2 * geometry.sideWidth + 2 * geometry.sideGap + 7 * geometry.letterWidth + 6 * geometry.gap + margins
    let punctuation =
      2 * geometry.sideWidth + 2 * geometry.sideGap + 5 * geometry.punctuationWidth + 4 * geometry.gap + margins
    let bottomGlobe =
      2 * geometry.abcWidth + geometry.spaceWidth(globe: true) + geometry.returnWidth + 3 * geometry.gap + margins
    let bottomFaceID =
      geometry.abcWidth + geometry.spaceWidth(globe: false) + geometry.returnWidth + 2 * geometry.gap + margins
    for (row, total) in [
      ("letters", letters), ("third", third), ("punctuation", punctuation), ("bottom with globe", bottomGlobe),
      ("bottom Face ID", bottomFaceID),
    ] {
      #expect(abs(total - width) < 0.5, "\(generation) \(width): \(row) row is \(total)")
    }
    // Every key is a key: wider than nothing, and the side keys wider than a letter.
    #expect(geometry.letterWidth > 0 && geometry.sideWidth > geometry.letterWidth)
    #expect(geometry.abcWidth > 0 && geometry.spaceWidth(globe: true) > geometry.returnWidth)
    #expect(geometry.returnWidth == 2 * geometry.abcWidth + geometry.gap)
    // On a Face ID phone the row is 123 · space · return: space is a globe and a gap wider.
    #expect(
      abs(geometry.spaceWidth(globe: false) - geometry.spaceWidth(globe: true) - geometry.abcWidth - geometry.gap)
        < 0.001)
  }

  @Test("the classic row is W/10 cells: a cap is its cell less two insets, 123 its share of a cell")
  func classicCells() {
    for width in Self.widths {
      let profile = Self.profile(.classic, width: width)
      let geometry = KeyGeometry(width: width, profile: profile)
      let cell = width / 10
      #expect(abs(geometry.letterWidth - (cell - 2 * profile.edgeInset)) < 0.001, "\(width)")
      #expect(
        abs(geometry.abcWidth - (DesignTokens.Metrics.classicAbcCells * cell - profile.keyGap)) < 0.001, "\(width)")
    }
  }

  /// The measured profiles, by the generation and width they stand for.
  nonisolated private static let measured: [(KeyboardProfile.Generation, String)] = [
    (.glass, "apple-geometry-glass-402"), (.classic, "apple-geometry-classic-390"),
    (.classic, "apple-geometry-classic-375"),
  ]

  @Test("at a measured width every number matches the profile's JSON within 0.5 pt", arguments: measured)
  func matchesMeasurement(generation: KeyboardProfile.Generation, file: String) throws {
    let measured = try AppleGeometry.load(file)
    let width = measured.width
    let profile = Self.profile(generation, width: width)
    #expect(profile.hasGlobe == (measured.cap["systemBarBelow"] == 0), "\(file): the globe is in the keyboard")
    let geometry = KeyGeometry(width: width, profile: profile)
    // The keys within half a point (pixels come in thirds); the band above
    // them and the whole height within one, since the surface's top edge is
    // read off an anti-aliased screenshot. Apple's own bottom row carries
    // the globe whatever the phone, so the measured space is the one beside it.
    let expectations = [
      Expectation("letter", geometry.letterWidth), Expectation("gap", geometry.gap),
      Expectation("sideGap", geometry.sideGap), Expectation("side", geometry.sideWidth),
      Expectation("abc", geometry.abcWidth), Expectation("return", geometry.returnWidth),
      Expectation("space", geometry.spaceWidth(globe: true)), Expectation("height", profile.keyHeight),
      Expectation("rowGap", profile.rowGap), Expectation("marginSide", profile.marginSide),
      Expectation("radius", profile.keyRadius), Expectation("topBand", profile.topBand, within: 1),
      Expectation("bottomMargin", profile.bottomInset),
      Expectation("keyboardHeight", KeyboardLayout.full.height(profile: profile), within: 1),
    ]
    for expectation in expectations {
      let key = expectation.key
      let number = try #require(measured.cap[key], "\(file) has no cap.\(key)")
      #expect(
        abs(number - expectation.value) < expectation.tolerance,
        "\(file): \(key) is \(number) measured, \(expectation.value) in the profile")
    }
  }

  /// One measured number against the profile's, within a tolerance.
  private struct Expectation {
    let key: String
    let value: CGFloat
    let tolerance: Double

    init(_ key: String, _ value: CGFloat, within tolerance: Double = 0.5) {
      self.key = key
      self.value = value
      self.tolerance = tolerance
    }
  }

  @Test("the heights per layout and generation, and the layout/* tokens that pin them")
  func heights() {
    let metrics = DesignTokens.Metrics.self
    let classic = Self.profile(.classic, width: 390)
    let glass = Self.profile(.glass, width: 402)
    #expect(KeyboardLayout.full.height(profile: glass) == metrics.layoutFull)
    #expect(KeyboardLayout.full.height(profile: classic) == metrics.layoutFullClassic)
    #expect(KeyboardLayout.slimBar.height(profile: glass) == metrics.layoutSlim)
    #expect(KeyboardLayout.slimBar.height(profile: classic) == metrics.layoutSlimClassic)
    #expect(KeyboardLayout.panel.height(profile: glass) == metrics.layoutPanel)
    #expect(KeyboardLayout.panel.height(profile: classic) == metrics.layoutPanel)
    // The height is the generation's, whatever the width.
    for width in Self.widths {
      #expect(KeyboardLayout.full.height(profile: Self.profile(.classic, width: width)) == metrics.layoutFullClassic)
    }
  }

  @Test("the system theme is the classic generation's; glass offers the brand alone and maps it there")
  func themes() {
    #expect(KeyboardPalette.all(for: .classic).map(\.id) == [KeyboardPalette.systemID, KeyboardPalette.brandID])
    #expect(KeyboardPalette.all(for: .glass).map(\.id) == [KeyboardPalette.brandID])
    #expect(KeyboardPalette.resolve(KeyboardPalette.systemID, dark: false, generation: .classic) == .systemLight)
    #expect(KeyboardPalette.resolve(KeyboardPalette.systemID, dark: true, generation: .classic) == .systemDark)
    #expect(KeyboardPalette.resolve(KeyboardPalette.systemID, dark: true, generation: .glass) == .brandDark)
    #expect(KeyboardPalette.resolve(KeyboardPalette.brandID, dark: false, generation: .classic) == .brandLight)
    #expect(KeyboardPalette.resolve("nope", dark: false, generation: .classic) == .brandLight)
    // The store's default id is the system theme's, so an untouched phone gets Apple's keys on classic.
    #expect(KeyboardPalette.systemID == "system")
    // The system theme's keys are Apple's, with no grain and no container colours of their own.
    #expect(KeyboardPalette.systemLight.key == DesignTokens.Brand.white)
    #expect(KeyboardPalette.systemLight.keyDark == DesignTokens.Brand.appleLightModifier)
    #expect(KeyboardPalette.systemLight.surface == DesignTokens.Brand.appleLightSurface)
    #expect(KeyboardPalette.systemDark.key == DesignTokens.Brand.appleDarkKey)
    #expect(KeyboardPalette.systemDark.keyDark == DesignTokens.Brand.appleDarkModifier)
    #expect(KeyboardPalette.systemDark.surface == DesignTokens.Brand.appleDarkSurface)
    #expect(KeyboardPalette.systemLight.grain == 0 && KeyboardPalette.systemDark.grain == 0)
    #expect(KeyboardPalette.systemLight.standIn(painted: true) == KeyboardPalette.systemLight.surface)
    #expect(KeyboardPalette.brandLight.standIn(painted: false) == KeyboardPalette.brandLight.material)
    // The model resolves through the profile: the system face on classic, the brand's on glass.
    let model = KeyboardModel()
    #expect(model.palette(for: Self.profile(.classic, width: 390)) == .systemLight)
    #expect(model.palette(for: Self.profile(.glass, width: 402)) == .brandLight)
  }

  @Test("the panel's element is capped so the + and the × keep their room on a narrow phone")
  func panelCap() {
    let metrics = DesignTokens.Metrics.self
    let clearance = 2 * (metrics.voicebarAddtermClearance + metrics.glyphHit)
    #expect(PanelView.micCap(rowWidth: 369) == min(VoiceSlot.panel.box.width, 369 - clearance))
    #expect(PanelView.micCap(rowWidth: 1000) == VoiceSlot.panel.box.width)
  }
}

/// One measured profile (`Design/apple-geometry-*.json`), bundled with the
/// tests: its width and the `cap` numbers scripts/apple-geometry.sh read.
struct AppleGeometry {
  let width: CGFloat
  let cap: [String: Double]
  let unmeasured: Bool

  private final class BundleToken {}

  static func load(_ file: String) throws -> AppleGeometry {
    let url = try #require(Bundle(for: BundleToken.self).url(forResource: file, withExtension: "json"))
    let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    let cap = try #require(json["cap"] as? [String: Any])
    var numbers: [String: Double] = [:]
    for (key, value) in cap {
      if let number = value as? NSNumber { numbers[key] = number.doubleValue }
    }
    let width = try #require(json["width"] as? NSNumber)
    return AppleGeometry(
      width: CGFloat(width.doubleValue), cap: numbers, unmeasured: (json["unmeasured"] as? Bool) ?? false)
  }
}

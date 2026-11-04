import BlurtDesign
import Foundation
import SwiftUI
import Testing
import UIKit

@testable import BlurtiOS
@testable import BlurtiOSCore

/// The compiled tokens against the file they were generated from. check.sh's
/// `design-sync.sh --check` catches drift in the tree; this catches it in the
/// binary, so a hand edit to `DesignTokens.swift` that slipped past both the
/// header and the check still fails somewhere.
@Suite("Design tokens")
struct DesignTokensTests {
  private final class BundleToken {}

  private static func tokensJSON() throws -> [String: Any] {
    let url = try #require(Bundle(for: BundleToken.self).url(forResource: "tokens", withExtension: "json"))
    return try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
  }

  /// A number the way scripts/design-tokens.swift prints it: `42`, `0.7`.
  private static func format(_ number: Double) -> String {
    number == number.rounded() ? String(Int(number)) : String(number)
  }

  /// tokens.json flattened to `group.name: value`, aliases followed — the same
  /// rendering the generator writes into `DesignTokens.manifest`.
  private static func expectedManifest() throws -> [String: String] {
    let json = try tokensJSON()
    let groups = ["brand", "themes", "keyboard", "metrics", "type", "motion"]
    var raw: [String: Any] = [:]
    for group in groups {
      let entries = try #require(json[group] as? [String: Any])
      for (name, entry) in entries {
        raw["\(group).\(name)"] = (entry as? [String: Any])?["value"] ?? entry
      }
    }
    func render(_ qualified: String, depth: Int = 0) throws -> String {
      let value = try #require(raw[qualified], "\(qualified) is not a token")
      try #require(depth < 8, "alias cycle at \(qualified)")
      if let number = value as? NSNumber { return format(number.doubleValue) }
      if let curve = value as? [NSNumber] { return curve.map { format($0.doubleValue) }.joined(separator: ",") }
      let string = try #require(value as? String)
      if string.hasPrefix("{"), string.hasSuffix("}") {
        return try render(String(string.dropFirst().dropLast()), depth: depth + 1)
      }
      return string.hasPrefix("#") ? string.uppercased() : string
    }
    var manifest: [String: String] = [:]
    for qualified in raw.keys { manifest[qualified] = try render(qualified) }
    let gradients = try #require(json["gradients"] as? [String: Any])
    for (name, entry) in gradients {
      let gradient = try #require(entry as? [String: Any])
      let stops = try #require(gradient["stops"] as? [[String: Any]])
      let rendered = try stops.map { stop -> String in
        let color = try #require(stop["color"] as? String)
        let location = try #require(stop["location"] as? NSNumber)
        let hex =
          color.hasPrefix("{") ? try render(String(color.dropFirst().dropLast())) : color.uppercased()
        return "\(hex)@\(format(location.doubleValue))"
      }
      let start = try #require(gradient["start"] as? String)
      let end = try #require(gradient["end"] as? String)
      manifest["gradients.\(name)"] = "\(rendered.joined(separator: " ")) \(start)>\(end)"
    }
    return manifest
  }

  @Test("every compiled token equals tokens.json (run scripts/design-sync.sh)")
  func manifest() throws {
    let expected = try Self.expectedManifest()
    let compiled = DesignTokens.manifest
    let missing = Set(expected.keys).subtracting(compiled.keys).sorted()
    let extra = Set(compiled.keys).subtracting(expected.keys).sorted()
    let changed = expected.keys.filter { compiled[$0] != nil && compiled[$0] != expected[$0] }.sorted()
    #expect(missing.isEmpty, "tokens in tokens.json but not compiled: \(missing)")
    #expect(extra.isEmpty, "tokens compiled but not in tokens.json: \(extra)")
    #expect(
      changed.isEmpty,
      "tokens whose value differs: \(changed.map { "\($0): \(compiled[$0] ?? "?") vs \(expected[$0] ?? "?")" })")
  }

  @Test("the layout heights are the rows at each generation's spacing, and the layout/* tokens agree")
  func heights() {
    let metrics = DesignTokens.Metrics.self
    let glass = KeyboardProfile(generation: .glass, width: metrics.keyReferenceWidth, hasGlobe: true)
    #expect(KeyboardLayout.slimBar.height(profile: glass) == 2 * metrics.marginVertical + metrics.voicebarHeight)
    #expect(KeyboardLayout.slimBar.height(profile: glass) == metrics.layoutSlim)
    #expect(KeyboardLayout.panel.height(profile: glass) == metrics.layoutPanel)
    #expect(
      KeyboardLayout.full.height(profile: glass)
        == metrics.marginVertical + metrics.voicebarHeight + 4 * metrics.keyHeight + 3 * metrics.rowGap
        + metrics.marginBottomKeys)
    #expect(KeyboardLayout.full.height(profile: glass) == metrics.layoutFull)
    let classic = KeyboardProfile(generation: .classic, width: 390, hasGlobe: false)
    #expect(KeyboardLayout.slimBar.height(profile: classic) == 2 * metrics.classicMarginTop + metrics.voicebarHeight)
    #expect(KeyboardLayout.slimBar.height(profile: classic) == metrics.layoutSlimClassic)
    #expect(KeyboardLayout.panel.height(profile: classic) == metrics.layoutPanel)
    #expect(
      KeyboardLayout.full.height(profile: classic)
        == metrics.classicMarginTop + metrics.voicebarHeight + 4 * metrics.classicKeyHeight
        + 3 * metrics.classicRowGap + metrics.classicBottomInset)
    #expect(KeyboardLayout.full.height(profile: classic) == metrics.layoutFullClassic)
    // The glass/* set is the measured key/*, row/* and margin/* tokens under the profile's names.
    #expect(metrics.glassKeyGap == metrics.keyGap && metrics.glassKeyHeight == metrics.keyHeight)
    #expect(metrics.glassRowGap == metrics.rowGap && metrics.glassMarginSide == metrics.marginSide)
    #expect(
      metrics.glassAbcWidth402 == metrics.keyAbcWidth402 && metrics.glassReferenceWidth == metrics.keyReferenceWidth)
  }

  @Test("the full layout at 402 pt matches the @402 tokens the design is drawn at")
  func fullLayoutAt402() {
    // The tokens are written to a thousandth of a point; the row's thirds
    // round either way at the last digit.
    let profile = KeyboardProfile(generation: .glass, width: DesignTokens.Metrics.keyReferenceWidth, hasGlobe: true)
    let geometry = KeyGeometry(width: DesignTokens.Metrics.keyReferenceWidth, profile: profile)
    #expect(abs(geometry.letterWidth - DesignTokens.Metrics.keyLetterWidth402) < 0.005)
    #expect(abs(geometry.sideWidth - DesignTokens.Metrics.keySideWidth402) < 0.005)
    #expect(abs(geometry.abcWidth - DesignTokens.Metrics.keyAbcWidth402) < 0.005)
    #expect(abs(geometry.returnWidth - DesignTokens.Metrics.keyReturnWidth402) < 0.005)
    #expect(abs(geometry.spaceWidth(globe: true) - DesignTokens.Metrics.keySpaceWidth402) < 0.005)
  }

  /// Each face beside the thirteen theme tokens it must equal, in role
  /// order: surface, key, modifier, legend, secondary legend, signal, pop-up,
  /// field, field border, notice, key in container, modifier in container,
  /// material.
  private static let paletteTokens: [(KeyboardPalette, [Color])] = {
    typealias Themes = DesignTokens.Themes
    return [
      (
        .brandLight,
        [
          Themes.lightSurface, Themes.lightKey, Themes.lightKeyModifier, Themes.lightLegend,
          Themes.lightLegendSecondary, Themes.lightSignal, Themes.lightPopup, Themes.lightField,
          Themes.lightFieldBorder, Themes.lightNotice, Themes.lightContainerKey, Themes.lightContainerKeyModifier,
          Themes.lightMaterial,
        ]
      ),
      (
        .brandDark,
        [
          Themes.darkSurface, Themes.darkKey, Themes.darkKeyModifier, Themes.darkLegend, Themes.darkLegendSecondary,
          Themes.darkSignal, Themes.darkPopup, Themes.darkField, Themes.darkFieldBorder, Themes.darkNotice,
          Themes.darkContainerKey, Themes.darkContainerKeyModifier, Themes.darkMaterial,
        ]
      ),
      (
        .systemLight,
        [
          Themes.systemLightSurface, Themes.systemLightKey, Themes.systemLightKeyModifier, Themes.systemLightLegend,
          Themes.systemLightLegendSecondary, Themes.systemLightSignal, Themes.systemLightPopup,
          Themes.systemLightField, Themes.systemLightFieldBorder, Themes.systemLightNotice,
          Themes.systemLightContainerKey, Themes.systemLightContainerKeyModifier, Themes.systemLightMaterial,
        ]
      ),
      (
        .systemDark,
        [
          Themes.systemDarkSurface, Themes.systemDarkKey, Themes.systemDarkKeyModifier, Themes.systemDarkLegend,
          Themes.systemDarkLegendSecondary, Themes.systemDarkSignal, Themes.systemDarkPopup, Themes.systemDarkField,
          Themes.systemDarkFieldBorder, Themes.systemDarkNotice, Themes.systemDarkContainerKey,
          Themes.systemDarkContainerKeyModifier, Themes.systemDarkMaterial,
        ]
      ),
    ]
  }()

  @Test("every face is its theme's tokens, role by role")
  func palettes() {
    // Two themes, two faces each: the brand on both generations, the system theme on classic.
    let offered = Set(KeyboardPalette.all(for: .classic).map(\.id) + KeyboardPalette.all(for: .glass).map(\.id))
    #expect(Self.paletteTokens.count == 2 * offered.count)
    for (palette, colors) in Self.paletteTokens {
      let roles = [
        palette.surface, palette.key, palette.keyDark, palette.keyText, palette.keyTextSecondary, palette.signal,
        palette.popupFill, palette.field, palette.fieldBorder, palette.notice, palette.containerKey,
        palette.containerKeyModifier, palette.material,
      ]
      #expect(roles == colors, "\(palette.id) \(palette.face)")
    }
  }

  @Test("the brand's faces carry the brand: ink under the dark face, paper under the light, green as the signal")
  func faces() {
    #expect(DesignTokens.Themes.darkSurface == DesignTokens.Brand.ink)
    #expect(DesignTokens.Themes.lightSurface == DesignTokens.Brand.paper200)
    #expect(DesignTokens.Themes.darkSignal == DesignTokens.Brand.green400)
    #expect(DesignTokens.Themes.lightSignal == DesignTokens.Brand.green700)
    #expect(DesignTokens.Themes.lightNotice == DesignTokens.Brand.orange)
    #expect(DesignTokens.Themes.darkNotice == DesignTokens.Brand.orange)
  }

  @Test(
    "BlurtDesign's chrome colours are the app's catalog colours, light and dark",
    arguments: [
      ("AccentColor", BlurtBrand.accent), ("Page", BlurtBrand.page), ("Text", BlurtBrand.text),
      ("Muted", BlurtBrand.muted), ("CardFill", BlurtBrand.cardFill), ("CardBorder", BlurtBrand.cardBorder),
      ("CTA", BlurtBrand.cta), ("CTAText", BlurtBrand.ctaText),
    ])
  func chromeMatchesCatalog(name: String, colour: Color) throws {
    // The catalog is what the system draws with (the global accent, the launch
    // screen); the library is what our views draw with. Both come from the same
    // token pair, so a mismatch is a generator or library bug.
    let catalog = try #require(UIColor(named: name), "\(name) is not in the app's catalog")
    for style in [UIUserInterfaceStyle.light, .dark] {
      let traits = UITraitCollection(userInterfaceStyle: style)
      #expect(
        Self.rgba(UIColor(colour).resolvedColor(with: traits)) == Self.rgba(catalog.resolvedColor(with: traits)),
        "\(name) in \(style == .dark ? "dark" : "light")")
    }
  }

  @Test("the CTA is the accent, so the accent is one token to repoint")
  func ctaIsTheAccent() {
    #expect(DesignTokens.Keyboard.appCtaLight == DesignTokens.Keyboard.appAccentLight)
    #expect(DesignTokens.Keyboard.appCtaDark == DesignTokens.Keyboard.appAccentDark)
  }

  /// The least a modifier cap must contrast with the surface it sits on to
  /// read as a key of its own: Apple's classic sets measure 1.43 (light) and
  /// 1.50 (dark).
  static let modifierContrastFloor = 1.3
  /// The brand's modifiers are quieter by design (DESIGN.md › Keys: flat, one
  /// colour): 1.21 and 1.10 on the painted faces, 1.13 and 1.28 in the host's
  /// container. This floor keeps them from vanishing (1.02 was the brand's
  /// light modifier on Apple's grey, before classic painted its surface).
  static let brandModifierContrastFloor = 1.09

  /// WCAG's relative luminance of a token colour, from its sRGB bytes.
  private static func luminance(_ colour: Color) -> Double {
    let rgba = Self.rgba(UIColor(colour)).map { Double($0) / 255 }
    func linear(_ channel: Double) -> Double {
      channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * linear(rgba[0]) + 0.7152 * linear(rgba[1]) + 0.0722 * linear(rgba[2])
  }

  /// The contrast ratio between two colours, 1 (the same) to 21.
  static func contrast(_ first: Color, _ second: Color) -> Double {
    let (one, two) = (luminance(first), luminance(second))
    return (max(one, two) + 0.05) / (min(one, two) + 0.05)
  }

  @Test(
    "every modifier cap contrasts with the surface it sits on, both generations, both faces",
    arguments: [KeyboardProfile.Generation.classic, .glass], [false, true])
  func modifierContrast(generation: KeyboardProfile.Generation, dark: Bool) {
    let profile = KeyboardProfile(generation: generation, width: 390, hasGlobe: false)
    for theme in KeyboardPalette.all(for: generation) {
      let palette = KeyboardPalette.resolve(theme.id, dark: dark, generation: generation)
      // What the keyboard draws: the key fill for this generation (the
      // container colours inside one) on the surface under it (the painted
      // face outside a container, the host's material inside one).
      let modifier = palette.keyFill(modifier: true, inContainer: profile.inContainer)
      let key = palette.keyFill(modifier: false, inContainer: profile.inContainer)
      let surface = palette.standIn(painted: profile.paintsSurface)
      let ratio = Self.contrast(modifier, surface)
      let floor = theme.id == KeyboardPalette.systemID ? Self.modifierContrastFloor : Self.brandModifierContrastFloor
      #expect(ratio >= floor, "\(theme.id) \(generation) \(dark ? "dark" : "light"): modifier/surface \(ratio)")
      #expect(Self.contrast(key, surface) >= floor, "\(theme.id) \(generation) \(dark ? "dark" : "light"): key/surface")
      // A modifier is a step away from an ordinary key.
      #expect(modifier != key, "\(theme.id) \(generation) \(dark ? "dark" : "light")")
    }
  }

  /// sRGB components to 8 bits, as the catalog stores them.
  private static func rgba(_ colour: UIColor) -> [Int] {
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var alpha: CGFloat = 0
    colour.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
    return [red, green, blue, alpha].map { Int(($0 * 255).rounded()) }
  }
}

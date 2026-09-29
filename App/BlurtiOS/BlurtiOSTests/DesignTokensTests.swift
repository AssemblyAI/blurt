import Foundation
import SwiftUI
import Testing
import UIKit

@testable import BlurtiOS

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
    let groups = ["brand", "themes", "keyboard", "metrics", "type", "motion", "fonts"]
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

  @Test("the layout heights are the rows at the token spacing, and the layout/* tokens agree")
  func heights() {
    let metrics = DesignTokens.Metrics.self
    #expect(KeyboardLayout.slimBar.height == 2 * metrics.marginVertical + metrics.voicebarHeight)
    #expect(KeyboardLayout.slimBar.height == metrics.layoutSlim)
    #expect(KeyboardLayout.panel.height == metrics.layoutPanel)
    #expect(
      KeyboardLayout.full.height
        == metrics.marginVertical + metrics.voicebarHeight + 4 * metrics.keyHeight + 3 * metrics.rowGap
        + metrics.marginBottomKeys)
    #expect(KeyboardLayout.full.height == metrics.layoutFull)
  }

  @Test("the full layout at 402 pt matches the @402 tokens the Figma frames are drawn with")
  func fullLayoutAt402() {
    // The tokens are written to a thousandth of a point; the row's thirds
    // round either way at the last digit.
    let geometry = KeyGeometry(width: DesignTokens.Metrics.keyReferenceWidth)
    #expect(abs(geometry.letterWidth - DesignTokens.Metrics.keyLetterWidth402) < 0.005)
    #expect(abs(geometry.sideWidth - DesignTokens.Metrics.keySideWidth402) < 0.005)
    #expect(abs(geometry.abcWidth - DesignTokens.Metrics.keyAbcWidth402) < 0.005)
    #expect(abs(geometry.returnWidth - DesignTokens.Metrics.keyReturnWidth402) < 0.005)
    #expect(abs(geometry.spaceWidth(globe: true) - DesignTokens.Metrics.keySpaceWidth402) < 0.005)
  }

  /// Each face beside the ten theme tokens it must equal, in role order:
  /// surface, key, modifier, legend, secondary legend, signal, pop-up, field,
  /// field border, notice.
  private static let paletteTokens: [(KeyboardPalette, [Color])] = {
    typealias Themes = DesignTokens.Themes
    return [
      (
        .brandLight,
        [
          Themes.lightSurface, Themes.lightKey, Themes.lightKeyModifier, Themes.lightLegend,
          Themes.lightLegendSecondary, Themes.lightSignal, Themes.lightPopup, Themes.lightField,
          Themes.lightFieldBorder, Themes.lightNotice,
        ]
      ),
      (
        .brandDark,
        [
          Themes.darkSurface, Themes.darkKey, Themes.darkKeyModifier, Themes.darkLegend, Themes.darkLegendSecondary,
          Themes.darkSignal, Themes.darkPopup, Themes.darkField, Themes.darkFieldBorder, Themes.darkNotice,
        ]
      ),
    ]
  }()

  @Test("every face is its theme's tokens, role by role")
  func palettes() {
    #expect(Self.paletteTokens.count == KeyboardPalette.all.count + 1)
    for (palette, colors) in Self.paletteTokens {
      let roles = [
        palette.surface, palette.key, palette.keyDark, palette.keyText, palette.keyTextSecondary, palette.signal,
        palette.popupFill, palette.field, palette.fieldBorder, palette.notice,
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

  @Test("the fonts are named by PostScript name and the bundle knows them")
  func fonts() {
    typealias Fonts = DesignTokens.Fonts
    for name in [
      Fonts.monoLight, Fonts.monoRegular, Fonts.monoMedium, Fonts.headingRegular, Fonts.bodyRegular, Fonts.bodyBold,
    ] {
      #expect(UIFont(name: name, size: 12) != nil, "\(name) is not registered (UIAppFonts / Design/fonts)")
    }
  }

  @Test("the drop is up at drop-rise, held to drop-hold, gone at drop")
  func drop() {
    #expect(PrismOrb.dropAmount(at: 0) == 0)
    #expect(PrismOrb.dropAmount(at: DesignTokens.Motion.dropRise) == 1)
    #expect(PrismOrb.dropAmount(at: DesignTokens.Motion.dropHold) == 1)
    #expect(PrismOrb.dropAmount(at: DesignTokens.Motion.drop) == 0)
    #expect(PrismOrb.dropAmount(at: -1) == 0)
  }
}

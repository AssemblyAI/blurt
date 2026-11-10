import BlurtDesign
import Foundation
import SwiftUI
import Testing
import UIKit

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

  private static func rgba(_ colour: UIColor) -> [Int] {
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var alpha: CGFloat = 0
    colour.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
    return [red, green, blue, alpha].map { Int(($0 * 255).rounded()) }
  }
}

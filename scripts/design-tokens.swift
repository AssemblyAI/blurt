#!/usr/bin/env swift  // The design's one source of numbers and colours, fanned out: reads  // App/BlurtiOS/Design/tokens.json (hand-edited: it is the  // source, not an export) and writes everything that used to repeat those values by  // hand — `App/BlurtiOS/BlurtDesign/DesignTokens.swift`, the generated tables in  // `App/BlurtiOS/DESIGN.md`, and the app's three asset-catalog colour sets. Run  // through scripts/design-sync.sh, which also formats the output and, with
// --check, fails on drift the way check.sh fails on a stale .pbxproj.
//
//   swift scripts/design-tokens.swift [--root <dir>]
//
// Inputs are always read from the repo; `--root` redirects the outputs (the
// drift check writes into .build/ and diffs). A `swift` script run from disk
// can't import the app, so this is plain Foundation.
//
// Token values: a hex string ("#01762F"), a number, a weight name, or an alias
// to another token in braces ("{brand.green/700}", the DTCG spelling). A value
// may be wrapped as {"value": …, "use": "one line for DESIGN.md"}. Swift names
// derive from token names by one rule — `kb/key-modifier` → `kbKeyModifier`,
// `green/700` → `green700`.

import Foundation

// MARK: - Arguments and paths

let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
let repoRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
var outputRoot = repoRoot
var arguments = Array(CommandLine.arguments.dropFirst())
while !arguments.isEmpty {
  let flag = arguments.removeFirst()
  switch flag {
  case "--root":
    guard !arguments.isEmpty else { fail("--root needs a directory") }
    outputRoot = URL(fileURLWithPath: arguments.removeFirst()).standardizedFileURL
  default:
    fail("unknown argument \(flag)")
  }
}

let tokensPath = "App/BlurtiOS/Design/tokens.json"
let swiftPath = "App/BlurtiOS/BlurtDesign/DesignTokens.swift"
let designPath = "App/BlurtiOS/DESIGN.md"
let catalogPath = "App/BlurtiOS/BlurtiOS/Assets.xcassets"

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data("design-tokens: \(message)\n".utf8))
  exit(1)
}

// MARK: - The model

enum Value {
  case color(String)  // "#RRGGBB"
  case number(Double)
  case word(String)  // a font weight
  case curve([Double])  // a cubic-bezier easing: four numbers
  case alias(String)  // "group.name"
}

struct Token {
  var group: String
  var name: String
  var value: Value
  var use: String?

  var qualified: String { "\(group).\(name)" }
  var swiftName: String { camel(name) }
}

struct Stop {
  let color: String  // alias or hex
  let location: Double
}

struct Gradient {
  let name: String
  let use: String?
  let start: String
  let end: String
  let stops: [Stop]
}

/// `kb/key-modifier` → `kbKeyModifier`; `green/700` → `green700`.
func camel(_ name: String) -> String {
  let parts = name.split(whereSeparator: { "/-.".contains($0) }).map(String.init)
  guard let first = parts.first else { return name }
  return ([first.lowercased()] + parts.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }).joined()
}

/// A group name to its Swift enum: `brand` → `Brand`. `type` becomes
/// `Typography`, since a member named `Type` is not allowed in Swift.
func typeName(_ group: String) -> String {
  group == "type" ? "Typography" : group.prefix(1).uppercased() + group.dropFirst()
}

func parseValue(_ raw: Any) -> Value {
  if let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
    return .number(number.doubleValue)
  }
  if let numbers = raw as? [NSNumber] {
    guard numbers.count == 4 else { fail("a curve is four numbers, got \(numbers)") }
    return .curve(numbers.map(\.doubleValue))
  }
  guard let string = raw as? String else { fail("a token value must be a string or a number, got \(raw)") }
  if string.hasPrefix("{"), string.hasSuffix("}") { return .alias(String(string.dropFirst().dropLast())) }
  if string.hasPrefix("#") {
    guard string.count == 7, string.dropFirst().allSatisfy(\.isHexDigit) else { fail("bad colour \(string)") }
    return .color(string.uppercased())
  }
  return .word(string)
}

// MARK: - Read

let tokensURL = repoRoot.appendingPathComponent(tokensPath)
guard let data = FileManager.default.contents(atPath: tokensURL.path),
  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
else { fail("could not read \(tokensPath)") }

let groups = ["brand", "themes", "keyboard", "metrics", "type", "motion"]
var tokens: [Token] = []
var byQualified: [String: Token] = [:]
for group in groups {
  guard let entries = json[group] as? [String: Any] else { fail("tokens.json has no \(group) group") }
  for name in entries.keys.sorted() {
    let entry = entries[name]!
    let token: Token
    if let wrapped = entry as? [String: Any] {
      guard let raw = wrapped["value"] else { fail("\(group).\(name) has no value") }
      token = Token(group: group, name: name, value: parseValue(raw), use: wrapped["use"] as? String)
    } else {
      token = Token(group: group, name: name, value: parseValue(entry), use: nil)
    }
    tokens.append(token)
    byQualified[token.qualified] = token
  }
}

var gradients: [Gradient] = []
if let entries = json["gradients"] as? [String: Any] {
  for name in entries.keys.sorted() {
    guard let entry = entries[name] as? [String: Any], let start = entry["start"] as? String,
      let end = entry["end"] as? String, let stops = entry["stops"] as? [[String: Any]]
    else { fail("gradients.\(name) needs start, end and stops") }
    gradients.append(
      Gradient(
        name: name, use: entry["use"] as? String, start: start, end: end,
        stops: stops.map { stop in
          guard let color = stop["color"] as? String, let location = stop["location"] as? NSNumber else {
            fail("gradients.\(name) has a stop without color and location")
          }
          return Stop(color: color, location: location.doubleValue)
        }))
  }
}

// MARK: - Resolve

/// Follows aliases to the concrete token, refusing cycles and dangling names.
func resolve(_ token: Token, seen: [String] = []) -> Token {
  guard case .alias(let target) = token.value else { return token }
  guard !seen.contains(target) else { fail("alias cycle at \(token.qualified)") }
  guard let next = byQualified[target] else { fail("\(token.qualified) aliases \(target), which does not exist") }
  return resolve(next, seen: seen + [token.qualified])
}

func resolveColor(_ reference: String) -> String {
  let value = parseValue(reference)
  switch value {
  case .color(let hex): return hex
  case .alias(let target):
    guard let token = byQualified[target] else { fail("\(reference) does not exist") }
    guard case .color(let hex) = resolve(token).value else { fail("\(reference) is not a colour") }
    return hex
  default: fail("\(reference) is not a colour")
  }
}

func format(_ number: Double) -> String {
  if number == number.rounded(), abs(number) < 1e9 { return String(Int(number)) }
  return String(number)
}

/// The value as the manifest and the docs print it.
func rendered(_ token: Token) -> String {
  switch resolve(token).value {
  case .color(let hex): return hex
  case .number(let number): return format(number)
  case .word(let word): return word
  case .curve(let numbers): return numbers.map(format).joined(separator: ",")
  case .alias: fatalError("unreachable")
  }
}

for token in tokens { _ = resolve(token) }  // every alias must land

// MARK: - Swift

let weights = ["ultraLight", "thin", "light", "regular", "medium", "semibold", "bold", "heavy", "black"]

func swiftLiteral(_ token: Token) -> (type: String, literal: String) {
  switch token.value {
  case .color(let hex): return ("Color", "Color(hex: 0x\(hex.dropFirst()))")
  case .number(let number):
    return (token.group == "motion" ? "Double" : "CGFloat", format(number))
  case .word(let word):
    guard weights.contains(word) else { fail("\(token.qualified): \(word) is not a font weight") }
    return ("Font.Weight", ".\(word)")
  case .curve(let numbers):
    let n = numbers.map(format)
    return (
      "UnitCurve",
      "UnitCurve.bezier(startControlPoint: UnitPoint(x: \(n[0]), y: \(n[1])), "
        + "endControlPoint: UnitPoint(x: \(n[2]), y: \(n[3])))"
    )
  case .alias(let target):
    guard let other = byQualified[target] else { fail("\(target) does not exist") }
    return (swiftLiteral(other).type, "\(typeName(other.group)).\(other.swiftName)")
  }
}

func swiftColorReference(_ reference: String) -> String {
  let value = parseValue(reference)
  switch value {
  case .color(let hex): return "Color(hex: 0x\(hex.dropFirst()))"
  case .alias(let target):
    guard let other = byQualified[target] else { fail("\(target) does not exist") }
    return "\(typeName(other.group)).\(other.swiftName)"
  default: fail("\(reference) is not a colour")
  }
}

func docComment(_ text: String?, indent: String) -> String {
  guard let text, !text.isEmpty else { return "" }
  return "\(indent)/// \(text.prefix(1).uppercased() + text.dropFirst()).\n"
}

var swift = """
  // Generated by scripts/design-tokens.swift from App/BlurtiOS/Design/tokens.json — do not edit.
  // Regenerate with scripts/design-sync.sh; scripts/check.sh fails on drift.
  // periphery:ignore:all
  // swiftlint:disable file_length
  import SwiftUI

  // swiftlint:disable type_body_length
  /// The design's colours and numbers, from their one source
  /// (`Design/tokens.json`): what the views draw with, what DESIGN.md's tables
  /// say, and what the asset catalog holds, all from the same file. Swift names
  /// follow the token names by one rule (`kb/key-modifier` → `kbKeyModifier`).
  /// `package`: BlurtDesign's, read by the app, the keyboard and the tests.
  package enum DesignTokens {

  """

for group in groups {
  swift += "  package enum \(typeName(group)) {\n"
  for token in tokens where token.group == group {
    let (type, literal) = swiftLiteral(token)
    let use = token.use.map { $0 } ?? (token.value.isAlias ? "`\(aliasTarget(token))`" : nil)
    swift += docComment(use, indent: "    ")
    swift += "    package nonisolated static let \(token.swiftName): \(type) = \(literal)\n"
  }
  swift += "  }\n\n"
}

swift += "  package enum Gradients {\n"
for gradient in gradients {
  swift += docComment(gradient.use, indent: "    ")
  swift += "    package nonisolated static let \(camel(gradient.name)) = LinearGradient(\n      stops: [\n"
  for stop in gradient.stops {
    swift += "        .init(color: \(swiftColorReference(stop.color)), location: \(format(stop.location))),\n"
  }
  swift += "      ],\n      startPoint: .\(gradient.start), endPoint: .\(gradient.end))\n"
}
swift += "  }\n\n"

swift += """
    /// Every token as `group.name: value`, the way tokens.json renders it, so a
    /// test can pin the compiled values to the file (`DesignTokensTests`).
    package nonisolated static let manifest: [String: String] = [

  """
for token in tokens {
  swift += "    \"\(token.qualified)\": \"\(rendered(token))\",\n"
}
for gradient in gradients {
  let stops = gradient.stops.map { "\(resolveColor($0.color))@\(format($0.location))" }.joined(separator: " ")
  swift += "    \"gradients.\(gradient.name)\": \"\(stops) \(gradient.start)>\(gradient.end)\",\n"
}
swift += "  ]\n}\n// swiftlint:enable type_body_length\n"

extension Value {
  var isAlias: Bool {
    if case .alias = self { return true }
    return false
  }
}

func aliasTarget(_ token: Token) -> String {
  if case .alias(let target) = token.value { return target }
  return ""
}

// MARK: - DESIGN.md

func table(_ header: [String], _ rows: [[String]]) -> String {
  var lines = ["| " + header.joined(separator: " | ") + " |"]
  lines.append("| " + header.map { _ in "---" }.joined(separator: " | ") + " |")
  for row in rows { lines.append("| " + row.joined(separator: " | ") + " |") }
  return lines.joined(separator: "\n")
}

func code(_ text: String) -> String { "`\(text)`" }

func tokenRows(_ group: String, valueLabel: String) -> String {
  let rows = tokens.filter { $0.group == group }.map { token -> [String] in
    var value = code(rendered(token))
    if case .alias(let target) = token.value { value += " (" + code(target) + ")" }
    return [code(token.name), value, code("\(typeName(group)).\(token.swiftName)"), token.use ?? "—"]
  }
  return table(["Token", valueLabel, "Swift", "Use"], rows)
}

var blocks: [String: String] = [:]
blocks["brand"] = tokenRows("brand", valueLabel: "Value")
blocks["keyboard"] = tokenRows("keyboard", valueLabel: "Value")
blocks["metrics"] = tokenRows("metrics", valueLabel: "Points")
blocks["type"] = tokenRows("type", valueLabel: "Value")
blocks["motion"] = tokenRows("motion", valueLabel: "Value")

let themeNames = tokens.filter { $0.group == "themes" }.map { String($0.name.split(separator: "/")[0]) }
let themeOrder = ["light", "dark"] + Set(themeNames).subtracting(["light", "dark"]).sorted()
let roles = [
  "surface", "key", "key-modifier", "legend", "legend-secondary", "signal", "popup", "field", "field-border", "notice",
  "container-key", "container-key-modifier", "material",
]
blocks["themes"] = table(
  [
    "Face", "Surface", "Key", "Modifier", "Legend", "Secondary", "Signal", "Pop-up", "Field", "Field border", "Notice",
    "Key in container", "Modifier in container", "Host material",
  ],
  themeOrder.compactMap { theme -> [String]? in
    let cells = roles.compactMap { role in byQualified["themes.\(theme)/\(role)"].map { code(rendered($0)) } }
    guard cells.count == roles.count else { return nil }
    return [code(theme)] + cells
  })

blocks["gradients"] = gradients.map { gradient in
  let stops = gradient.stops.map { "\(code(resolveColor($0.color))) at \(format($0.location))" }
    .joined(separator: ", ")
  return
    "- \(code(gradient.name)) (\(code("Gradients.\(camel(gradient.name))")), \(gradient.start) → \(gradient.end)): \(stops)"
    + (gradient.use.map { " — \($0)" } ?? "")
}.joined(separator: "\n")

let designURL = repoRoot.appendingPathComponent(designPath)
guard var design = try? String(contentsOf: designURL, encoding: .utf8) else { fail("could not read \(designPath)") }
var replaced: Set<String> = []
for (name, body) in blocks {
  let begin = "<!-- tokens:begin \(name) -->"
  let end = "<!-- tokens:end \(name) -->"
  guard let beginRange = design.range(of: begin),
    let endRange = design.range(of: end, range: beginRange.upperBound..<design.endIndex)
  else { continue }
  design.replaceSubrange(beginRange.upperBound..<endRange.lowerBound, with: "\n\n\(body)\n\n")
  replaced.insert(name)
}
let missing = Set(blocks.keys).subtracting(replaced)
guard missing.isEmpty else { fail("\(designPath) has no markers for: \(missing.sorted().joined(separator: ", "))") }

// MARK: - Asset catalog

func catalog(light: String, dark: String) -> String {
  // Xcode's own layout, byte for byte: eight spaces in front of the colour's
  // keys, ten in front of its components.
  func components(_ hex: String) -> String {
    let digits = Array(hex.dropFirst())
    let red = String(digits[0...1])
    let green = String(digits[2...3])
    let blue = String(digits[4...5])
    return [
      "        \"color-space\" : \"srgb\",",
      "        \"components\" : {",
      "          \"alpha\" : \"1.000\",",
      "          \"blue\" : \"0x\(blue)\",",
      "          \"green\" : \"0x\(green)\",",
      "          \"red\" : \"0x\(red)\"",
      "        }",
    ].joined(separator: "\n")
  }
  return """
    {
      "colors" : [
        {
          "color" : {
    \(components(light))
          },
          "idiom" : "universal"
        },
        {
          "appearances" : [
            {
              "appearance" : "luminosity",
              "value" : "dark"
            }
          ],
          "color" : {
    \(components(dark))
          },
          "idiom" : "universal"
        }
      ],
      "info" : {
        "author" : "xcode",
        "version" : 1
      }
    }

    """
}

let colorSets: [(String, String, String)] = [
  ("AccentColor", "keyboard.app/accent-light", "keyboard.app/accent-dark"),
  ("CardFill", "keyboard.app/card-fill-light", "keyboard.app/card-fill-dark"),
  ("CardBorder", "keyboard.app/card-border-light", "keyboard.app/card-border-dark"),
  ("Page", "keyboard.app/page-light", "keyboard.app/page-dark"),
  ("Text", "keyboard.app/text-light", "keyboard.app/text-dark"),
  ("Muted", "keyboard.app/muted-light", "keyboard.app/muted-dark"),
  ("CTA", "keyboard.app/cta-light", "keyboard.app/cta-dark"),
  ("CTAText", "keyboard.app/cta-text-light", "keyboard.app/cta-text-dark"),
]

// MARK: - Write

func write(_ text: String, to relative: String) {
  let url = outputRoot.appendingPathComponent(relative)
  do {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
  } catch {
    fail("could not write \(relative): \(error)")
  }
}

write(swift, to: swiftPath)
write(design, to: designPath)
for (set, light, dark) in colorSets {
  guard let lightToken = byQualified[light], let darkToken = byQualified[dark] else {
    fail("\(set) needs \(light) and \(dark)")
  }
  write(
    catalog(light: rendered(lightToken), dark: rendered(darkToken)), to: "\(catalogPath)/\(set).colorset/Contents.json")
}
print(
  "design-tokens: \(tokens.count) tokens, \(gradients.count) gradients → \(swiftPath), \(designPath) "
    + "(\(replaced.count) blocks), \(colorSets.count) colour sets")

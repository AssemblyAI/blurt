import Foundation
import Testing

@testable import BlurtEngine

/// The reply parser fuzzed: every model reply crosses it, so whatever comes
/// back — a plan off by one field, garbage, a reply cut in two — it either
/// refuses with a `VoiceCommandError` or answers a plan that keeps every rule
/// the parser exists for. Seeded, so a failure replays exactly.
@Suite("Reply parser fuzz")
struct ReplyParserFuzzTests {
  /// xorshift64*: small, fast, and the same sequence for the same seed.
  struct Seeded: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
      state ^= state >> 12
      state ^= state << 25
      state ^= state >> 27
      return state &* 2_685_821_657_736_338_717
    }
  }

  static let listed: [ScreenContext.Element] = [
    .init(id: 1, kind: "button", label: "Send"), .init(id: 2, kind: "row", label: "Inbox"),
    .init(id: 3, kind: "text field", label: "Search"), .init(id: 4, kind: "slider", label: "Volume"),
    .init(id: 5, kind: "button", label: "Delete"), .init(id: 6, kind: "link", label: "Docs"),
  ]

  /// Values a field might be sent, plausible and not.
  static let strings = [
    "", " ", "Slack", "cmd+t", "cmd+delete", "cmd+shift+q", "return", "escape", "shift+cmd+\\", "tab",
    "https://example.com", "file:///etc/passwd", "javascript:alert(1)", "mailto:a@b.c", "x-apple.systempreferences:",
    "Delete", "Move to Trash", "Empty Trash", "Log Out", "\u{202E}evil", "line\nbreak", "\"quoted\"", "😀", "up",
    "left_half", "spin", "volume_up", "brightness_down", "nope", String(repeating: "a", count: 2_001),
  ]

  static func value(_ rng: inout Seeded) -> Any {
    switch Int.random(in: 0..<8, using: &rng) {
    case 0: return strings.randomElement(using: &rng) ?? ""
    case 1: return Int.random(in: -3...9, using: &rng)
    case 2: return [Int.max, Int.min, 0, 1_000_000][Int.random(in: 0..<4, using: &rng)]
    case 3: return Double.random(in: -1e6...1e6, using: &rng)
    case 4: return Bool.random(using: &rng)
    case 5: return NSNull()
    case 6: return (0..<Int.random(in: 0...5, using: &rng)).map { _ in strings.randomElement(using: &rng) ?? "" }
    default: return ["nested": strings.randomElement(using: &rng) ?? ""]
    }
  }

  static func pick(_ values: [String], _ rng: inout Seeded) -> String { values.randomElement(using: &rng) ?? "" }

  /// A step shaped like the schema asks: an action and its own fields, each
  /// of the right type but any value — the replies that reach the rules.
  static func plausibleStep(_ rng: inout Seeded) -> [String: Any] {
    let action = VoiceCommandStep.Action.allCases.randomElement(using: &rng) ?? .press
    var step: [String: Any] = ["action": action.rawValue]
    let named = namedFields(action, &rng)
    step.merge(named.isEmpty ? elementFields(action, &rng) : named) { _, new in new }
    return step
  }

  /// The fields of an action that names what it acts on; empty for one on a listed element.
  static func namedFields(_ action: VoiceCommandStep.Action, _ rng: inout Seeded) -> [String: Any] {
    switch action {
    case .openApp, .quitApp, .hideApp: ["app": pick(["Slack", "Finder", "", "Terminal"], &rng)]
    case .openURL: ["url": pick(strings.filter { $0.contains(":") }, &rng)]
    case .shortcut:
      ["keys": pick(["cmd+t", "cmd+delete", "cmd+shift+q", "return", "tab", "cmd+", "option+cmd+escape"], &rng)]
    case .type: ["text": pick(strings, &rng)]
    case .media: ["control": pick(MediaKey.allCases.map(\.rawValue) + ["eject", "power"], &rng)]
    case .pressButton: ["name": pick(["Send", "Delete", "Move to Trash", "Reply", ""], &rng)]
    case .menu:
      ["path": (0..<Int.random(in: 0...6, using: &rng)).map { _ in pick(["File", "Delete", "Edit", "Log Out"], &rng) }]
    case .window: ["operation": pick(WindowOperation.allCases.map(\.rawValue) + ["spin"], &rng)]
    default: [:]
    }
  }

  /// The fields of an action on a listed element: its number, any of them.
  static func elementFields(_ action: VoiceCommandStep.Action, _ rng: inout Seeded) -> [String: Any] {
    let element = Int.random(in: 0...7, using: &rng)
    switch action {
    case .scroll:
      var fields: [String: Any] = ["direction": pick(ScrollDirection.allCases.map(\.rawValue) + ["sideways"], &rng)]
      if Bool.random(using: &rng) { fields["element"] = element }
      return fields
    case .setValue: return ["element": element, "value": Double.random(in: -10...200, using: &rng)]
    default: return ["element": element]
    }
  }

  /// A step: a real action (or not), and a random handful of fields.
  static func step(_ rng: inout Seeded) -> [String: Any] {
    if Int.random(in: 0..<4, using: &rng) > 0 { return plausibleStep(&rng) }
    var step: [String: Any] = [:]
    if Int.random(in: 0..<10, using: &rng) > 0 {
      step["action"] =
        Int.random(in: 0..<12, using: &rng) == 0
        ? "run_shell" : VoiceCommandStep.Action.allCases.randomElement(using: &rng)?.rawValue ?? "press"
    }
    for field in VoiceCommandStep.Field.allCases where field != .action && Bool.random(using: &rng) {
      step[field.rawValue] = value(&rng)
    }
    return step
  }

  static func reply(_ rng: inout Seeded) -> String {
    let steps = (0..<Int.random(in: 0...12, using: &rng)).map { _ in step(&rng) }
    let object: Any = Int.random(in: 0..<20, using: &rng) == 0 ? steps : ["steps": steps]
    let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    var text = String(bytes: data, encoding: .utf8) ?? ""
    // Damage some: cut short, a byte flipped, prose around it, a fence.
    switch Int.random(in: 0..<10, using: &rng) {
    case 0 where !text.isEmpty: text = String(text.prefix(Int.random(in: 0..<text.count, using: &rng)))
    case 1 where !text.isEmpty:
      var chars = Array(text)
      chars[Int.random(in: 0..<chars.count, using: &rng)] =
        ["{", "}", "\"", ",", ":", "x"].randomElement(using: &rng) ?? "x"
      text = String(chars)
    case 2: text = "Here is the plan:\n" + text
    case 3: text = "```json\n" + text + "\n```"
    default: break
    }
    return text
  }

  /// Every rule a parsed plan must keep, whatever reply it came from.
  static func check(_ steps: [VoiceCommandStep], reply: String) {
    let ids = Set(listed.map(\.id))
    #expect((1...10).contains(steps.count), "\(reply)")
    for step in steps {
      if let id = step.elementID { #expect(ids.contains(id), "unlisted \(id): \(reply)") }
      switch step {
      case .shortcut(let chord): #expect(!DestructiveGuard.isDestructive(chord), "\(reply)")
      case .openURL(let url):
        #expect(VoiceCommandStep.allowedSchemes.contains(url.scheme?.lowercased() ?? ""), "\(reply)")
      case .type(let text): #expect(!text.isEmpty && text.count <= VoiceCommandStep.maxTypedCharacters, "\(reply)")
      case .pressButton(let name): #expect(!DestructiveGuard.isDestructive(label: name), "\(reply)")
      case .chooseMenuItem(let path):
        #expect((1...VoiceCommandStep.maxMenuDepth).contains(path.count), "\(reply)")
        #expect(!path.contains(where: DestructiveGuard.isDestructive(label:)), "\(reply)")
      case .pressElement(let id), .showMenu(let id):
        let label = listed.first { $0.id == id }?.label ?? ""
        #expect(!DestructiveGuard.isDestructive(label: label), "\(reply)")
      default: break
      }
    }
    #expect(VoiceCommandStep.repeatedBlock(in: steps).isEmpty, "\(reply)")
  }

  @Test("generated and damaged replies: refused with a VoiceCommandError, or a plan that keeps every rule")
  func fuzz() {
    var rng = Seeded(state: 0xB1_0B_2026)
    var parsed = 0
    for _ in 0..<20_000 {
      let reply = Self.reply(&rng)
      do {
        let steps = try VoiceCommandStep.steps(fromReply: reply, maxSteps: 10, listed: Self.listed)
        parsed += 1
        Self.check(steps, reply: reply)
      } catch is VoiceCommandError {
      } catch {
        Issue.record("not a VoiceCommandError: \(error) for \(reply)")
      }
    }
    // The generator has to reach the rules, not only the JSON decoder.
    #expect(parsed > 200)
  }

  @Test("arbitrary bytes and strings are refused, never crash")
  func garbage() {
    var rng = Seeded(state: 42)
    for _ in 0..<5_000 {
      let bytes = (0..<Int.random(in: 0...64, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) }
      let text = String(bytes: bytes, encoding: .utf8) ?? String(bytes.map { Character(Unicode.Scalar($0)) })
      #expect(throws: VoiceCommandError.self) {
        try VoiceCommandStep.steps(fromReply: text, maxSteps: 10, listed: Self.listed)
      }
    }
  }
}

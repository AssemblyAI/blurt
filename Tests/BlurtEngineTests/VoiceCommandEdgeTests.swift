import Foundation
import Testing

@testable import BlurtEngine

/// Small edges of the Control Your Mac key: the plan schema's closed objects,
/// the pill for a missing menu item, and how the command log names things.
@Suite("Voice command · schema, pill and log edges")
struct VoiceCommandEdgeTests {
  @Test("the plan and every step branch are closed objects: no field the parser doesn't read")
  func schemaIsClosed() throws {
    let data = try JSONEncoder().encode(VoiceCommandPlanner.responseFormat)
    let format = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let schema = try #require((format["json_schema"] as? [String: Any])?["schema"] as? [String: Any])
    #expect(schema["additionalProperties"] as? Bool == false)
    let steps = try #require((schema["properties"] as? [String: Any])?["steps"] as? [String: Any])
    let branches = try #require((steps["items"] as? [String: Any])?["anyOf"] as? [[String: Any]])
    #expect(!branches.isEmpty)
    for branch in branches {
      #expect(branch["additionalProperties"] as? Bool == false)
    }
  }

  @Test("a menu path that isn't there is named on the pill by its last item")
  func menuPillNamesTheLeaf() {
    let notice = VoiceCommandError.menuItemNotFound(["File", "Export…"]).pillNotice
    #expect(notice == PillNotice(subject: "Export…", predicate: "isn’t in the menus"))
  }

  @Test("the log names an element by the first listed under its number")
  func logLineTakesTheFirstListed() {
    let context = ScreenContext(
      appName: "Mail",
      elements: [.init(id: 3, kind: "button", label: "Send"), .init(id: 3, kind: "link", label: "Inbox")])
    #expect(VoiceCommandStep.pressElement(3).logLine(in: context).contains(#"(button "Send")"#))
  }

  @Test("a log's location is shown unescaped, a space as a space")
  func displayPathIsUnescaped() {
    let url = URL(filePath: "/Volumes/Work Disk/Logs/My App/commands.jsonl")
    #expect(DictationLog.displayPath(of: url) == "/Volumes/Work Disk/Logs/My App/commands.jsonl")
    #expect(DictationLog.defaultCommandDisplayPath.hasSuffix("commands.jsonl"))
  }
}

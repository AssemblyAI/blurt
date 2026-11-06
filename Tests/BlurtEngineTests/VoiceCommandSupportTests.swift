import Foundation
import Testing

@testable import BlurtEngine

// The command code's smaller pieces, one suite per type.

@Suite("DestructiveGuard")
struct DestructiveGuardTests {
  @Test("a button or menu item that deletes, erases or powers off is refused, by whole words")
  func destructiveLabels() {
    for label in ["Move to Trash", "Empty Trash…", "Delete", "Erase Disk", "Shut Down…", "Restart", "Log Out Alex…"] {
      #expect(DestructiveGuard.isDestructive(label: label), "\(label)")
    }
    for label in ["Send", "Show Log", "Format", "Restarted Jobs", "Deleted Items Folder"] {
      #expect(!DestructiveGuard.isDestructive(label: label), "\(label)")
    }
  }
}

@Suite("ElementSearch")
struct ElementSearchTests {
  @Test("the element search finds the pressable one by label, nearest the top first, within its limit")
  func elementSearch() {
    struct Node {
      let label: String
      let pressable: Bool
      var children: [Node] = []
    }
    let tree = Node(
      label: "window", pressable: false,
      children: [
        Node(label: "Send", pressable: false),
        Node(
          label: "toolbar", pressable: false,
          children: [Node(label: "Send Later", pressable: true), Node(label: "Send", pressable: true)]),
        Node(label: "body", pressable: false, children: [Node(label: "Send", pressable: true, children: [])]),
      ])
    func find(_ name: String, limit: Int = ElementSearch.maxElements) -> Node? {
      ElementSearch.best(
        named: name, from: tree, children: \.children, labels: { [$0.label] }, pressable: \.pressable, limit: limit)
    }
    #expect(find("send")?.label == "Send")
    #expect(find("send later")?.label == "Send Later")
    #expect(find("Archive") == nil)
    // Three nodes in, it hasn't reached the toolbar's buttons.
    #expect(find("send", limit: 3) == nil)
  }
}

@Suite("WindowOrder")
struct WindowOrderTests {
  @Test("an app is in front when its window is the top normal one, panels and the menu bar aside")
  func windowOrder() {
    let menuBar = WindowOrder.Window(owner: 1, layer: 24)
    let pill = WindowOrder.Window(owner: 9, layer: 3)
    #expect(WindowOrder.isFrontmost(5, in: [menuBar, pill, .init(owner: 5, layer: 0), .init(owner: 6, layer: 0)]))
    #expect(!WindowOrder.isFrontmost(5, in: [menuBar, .init(owner: 6, layer: 0), .init(owner: 5, layer: 0)]))
    // Whose window a click lands in: the top normal-layer window there,
    // whatever floats above it.
    let spot = CGPoint(x: 100, y: 100)
    let music = WindowOrder.Window(owner: 5, layer: 0, bounds: CGRect(x: 0, y: 0, width: 800, height: 600))
    let code = WindowOrder.Window(owner: 6, layer: 0, bounds: CGRect(x: 50, y: 50, width: 200, height: 200))
    #expect(WindowOrder.owner(at: spot, in: [menuBar, code, music]) == 6)
    #expect(WindowOrder.owner(at: CGPoint(x: 700, y: 500), in: [menuBar, code, music]) == 5)
    #expect(WindowOrder.owner(at: CGPoint(x: 900, y: 900), in: [code, music]) == nil)
    // No window of its own on screen: nothing to wait for.
    #expect(WindowOrder.isFrontmost(5, in: [menuBar, .init(owner: 6, layer: 0)]))
  }
}

@Suite("NameMatch")
struct NameMatchTests {
  @Test("a menu item's ellipsis doesn't stop it matching")
  func menuEllipsis() {
    #expect(NameMatch.best(for: "Export", among: ["Export…", "Export as PDF…"]) == "Export…")
    #expect(NameMatch.best(for: "page setup", among: ["Page Setup..."]) == "Page Setup...")
  }
}

@Suite("AppLink")
struct AppLinkTests {
  private func url(_ string: String) -> URL { URL(string: string) ?? URL(fileURLWithPath: "/") }
  private let apps: (String) -> String? = { ["slack": "Slack", "music": "Music"][$0.lowercased()] }

  @Test("a bare site or a short web search stands for a name; a real page doesn't")
  func names() {
    #expect(AppLink.name(in: url("https://slack.com")) == "slack")
    #expect(AppLink.name(in: url("https://www.slack.com/")) == "slack")
    #expect(AppLink.name(in: url("https://www.google.com/search?q=Slack")) == "Slack")
    #expect(AppLink.name(in: url("https://slack.com/pricing")) == nil)
    #expect(AppLink.name(in: url("https://www.google.com/search?q=how+to+open+threads+in+slack")) == nil)
    #expect(AppLink.name(in: url("https://docs.google.com")) == nil)
  }

  @Test("switch to Slack opens Slack, not slack.com — unless the web is what was asked for")
  func prefersApps() {
    let site: [VoiceCommandStep] = [.openURL(url("https://slack.com"))]
    let search: [VoiceCommandStep] = [.openURL(url("https://www.google.com/search?q=Music"))]
    #expect(AppLink.preferApps(site, said: "Switch to Slack.", app: apps) == [.openApp("Slack")])
    #expect(AppLink.preferApps(search, said: "Open Music", app: apps) == [.openApp("Music")])
    #expect(AppLink.preferApps(site, said: "Go to slack.com", app: apps) == site)
    #expect(AppLink.preferApps(site, said: "Open the Slack website", app: apps) == site)
    #expect(AppLink.preferApps(search, said: "Search Google for music", app: apps) == search)
    // A bare "open Zoom" pressing a listed mailbox named Zoom opens the app;
    // "open activity" in Slack, which names no app, still presses its tab.
    let zoomApp: (String) -> String? = { $0.lowercased() == "zoom" ? "zoom.us" : nil }
    let mailbox = [ScreenContext.Element(id: 21, kind: "row", label: "Zoom")]
    #expect(
      AppLink.preferApps([.pressElement(21)], said: "Open Zoom.", listed: mailbox, app: zoomApp) == [
        .openApp("zoom.us")
      ])
    let tab = [ScreenContext.Element(id: 19, kind: "tab or option", label: "Activity")]
    #expect(
      AppLink.preferApps([.pressElement(19)], said: "Open activity", listed: tab, app: zoomApp) == [.pressElement(19)])
    let mail: (String) -> String? = { $0.lowercased() == "mail" ? "Mail" : nil }
    #expect(AppLink.preferApps([.openURL(url("mailto:"))], said: "Switch to Mail", app: mail) == [.openApp("Mail")])
    // Writing to someone stays a mailto: it names a person, not just the app.
    let toSam: [VoiceCommandStep] = [.openURL(url("mailto:sam@example.com"))]
    #expect(AppLink.preferApps(toSam, said: "Email Sam", app: mail) == toSam)
    let preview: (String) -> String? = { $0.lowercased() == "preview" ? "Preview" : nil }
    let cmdTab = VoiceCommandStep.shortcut(KeyChord(modifiers: .command, key: .code(0x30)))
    #expect(AppLink.preferApps([cmdTab], said: "Open Preview", app: preview) == [.openApp("Preview")])
    // "Go to home" in Finder is ⇧⌘H, not the Home app.
    let home: (String) -> String? = { $0.lowercased() == "home" ? "Home" : nil }
    let goHome = VoiceCommandStep.shortcut(KeyChord(modifiers: [.command, .shift], key: .character("h")))
    #expect(AppLink.preferApps([goHome], said: "Go to home", app: home) == [goHome])
    #expect(AppLink.openedName("Switch to the Slack app") == "slack")
    #expect(AppLink.openedName("click on Salesforce") == nil)
    let notAnApp: [VoiceCommandStep] = [.openURL(url("https://github.com"))]
    #expect(AppLink.preferApps(notAnApp, said: "Open GitHub", app: apps) == notAnApp)
  }
}

@Suite("Collection.onlyElement")
struct OnlyElementTests {
  @Test("the one element when there is exactly one; none for none, or for several")
  func onlyElement() {
    #expect([7].onlyElement == 7)
    #expect([Int]().onlyElement == nil)
    #expect([7, 8].onlyElement == nil)
    #expect("x".onlyElement == "x")
    #expect("xy".onlyElement == nil)
  }
}

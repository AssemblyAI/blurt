import Foundation
import Testing

@testable import BlurtEngine

@Suite("AppLink")
struct AppLinkTests {
  private let apps: (String) -> String? = { ["slack": "Slack", "music": "Music"][$0.lowercased()] }

  private func url(_ string: String) -> URL { URL(string: string) ?? URL(fileURLWithPath: "/") }

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

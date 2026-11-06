import Foundation
import Testing

@testable import BlurtEngine

/// The tie-breaks and edges of matching a spoken name: which of two equal
/// candidates wins, when a search stops, and when a link or a step stands for
/// an app.
@Suite("Command matching · tie-breaks and edges")
struct CommandMatchingTests {
  private struct Item {
    let id: Int
    var labels: [String] = []
    var children: [Item] = []
  }

  @Test("of two names the same once folded, the first listed wins")
  func exactTieGoesToTheFirst() {
    #expect(NameMatch.best(for: "notes", among: ["Notes", "Notes…"]) == "Notes")
    #expect(NameMatch.best(for: "notes", among: ["Notes…", "Notes"]) == "Notes…")
  }

  @Test("of names holding the word, the shortest wins")
  func wholeWordTakesTheShortest() {
    #expect(NameMatch.best(for: "chrome", among: ["Google Chrome Canary", "Google Chrome"]) == "Google Chrome")
  }

  @Test("an exact match ends the search there")
  func exactMatchStopsTheWalk() {
    let root = Item(
      id: 0,
      children: [Item(id: 1, labels: ["Save"]), Item(id: 2, labels: ["Save As…"]), Item(id: 3, labels: ["Save"])])
    var asked: [Int] = []
    let found = ElementSearch.best(
      named: "save", from: root, children: \.children,
      labels: {
        asked.append($0.id)
        return $0.labels
      }, pressable: { _ in true })
    #expect(found?.id == 1)
    #expect(asked == [0, 1])
  }

  @Test("the caller's stop ends the search before it looks at anything")
  func callerStopEndsTheSearch() {
    let root = Item(id: 0, children: [Item(id: 1, labels: ["Send"])])
    let found = ElementSearch.best(
      named: "send", from: root, children: \.children, labels: \.labels, pressable: { _ in true },
      shouldStop: { true })
    #expect(found == nil)
  }

  @Test("of two the same label, the one nearer the top level wins")
  func nearerOfTwoTheSameLabelWins() {
    let root = Item(
      id: 0,
      children: [Item(id: 1, children: [Item(id: 3, labels: ["Send Now"])]), Item(id: 2, labels: ["Send Now"])])
    let found = ElementSearch.best(
      named: "send", from: root, children: \.children, labels: \.labels, pressable: { _ in true })
    #expect(found?.id == 2)
  }

  @Test("a web search names its first query")
  func searchNamesItsFirstQuery() throws {
    let url = try #require(URL(string: "https://www.google.com/search?q=slack&q=zoom"))
    #expect(AppLink.name(in: url) == "slack")
  }

  @Test("the web is asked for by a word beside punctuation, or a real domain — not a trailing full stop")
  func asksForWebEdges() {
    #expect(AppLink.asksForWeb("Search, Slack"))
    #expect(AppLink.asksForWeb("open slack.com"))
    #expect(!AppLink.asksForWeb("Open Slack."))
    #expect(!AppLink.asksForWeb("open slack"))
  }

  @Test("a bare \"open X\" step stands for the app only as a link, ⌘Tab, or a press of something listed as X")
  func standsForAppOnlyWhenListedUnderTheName() {
    let zoom = { (name: String) -> String? in name == "zoom" ? "zoom.us" : nil }
    // The first element listed under a number answers, as the parse's lookup does.
    let listed: [ScreenContext.Element] = [
      .init(id: 5, kind: "row", label: "Zoom"), .init(id: 5, kind: "row", label: "Inbox"),
    ]
    #expect(
      AppLink.preferApps([.pressElement(5)], said: "open zoom", listed: listed, app: zoom) == [.openApp("zoom.us")])
    // Nothing listed under the number: the press stays.
    #expect(AppLink.preferApps([.pressElement(5)], said: "open zoom", app: zoom) == [.pressElement(5)])
    // A step of any other kind stays.
    #expect(AppLink.preferApps([.type("zoom")], said: "open zoom", app: zoom) == [.type("zoom")])
  }
}

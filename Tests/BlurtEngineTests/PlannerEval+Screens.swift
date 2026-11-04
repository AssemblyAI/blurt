import Foundation
import Testing

@testable import BlurtEngine

/// Cases built over the recorded screens (`Tests/ScreenTrees`): each a full
/// window as a command would see it — up to 150 elements, in the app's own
/// order, kinds and clutter — rather than the handful a written case lists.
/// Their text is fake ("Lorem 12") but for generic interface words, so a
/// command names one of those ("click Activity") or an element by its fake
/// name ("click on Lorem 47"): both ask the planner to find one element
/// among everything a real window lists. Seeded, so a run asks the same.
extension PlannerEval {
  static func screenCases() throws -> [Case] {
    try RecordedNode.recordings.flatMap { name in try screenCases(for: name) }
  }

  /// The kinds a "click" means a press or a select of.
  static let clickable: Set<String> = [
    "button", "link", "checkbox", "tab or option", "clickable", "menu button", "pop-up menu", "row", "menu item",
    "disclosure triangle",
  ]

  static func screenCases(for name: String) throws -> [Case] {
    let context = try RecordedNode.context(name)
    let counts = Dictionary(grouping: context.elements, by: \.label).mapValues(\.count)
    let unique = context.elements.filter { counts[$0.label] == 1 && clickable.contains($0.kind) }
    var cases: [Case] = []

    // Every interface word listed once: a command a user would say.
    for element in unique where !element.label.hasPrefix("Lorem ") {
      let refused = DestructiveGuard.isDestructive(label: element.label)
      cases.append(
        Case(
          id: "\(name)-click-\(element.label)", said: "Click \(element.label)", context: context,
          expect: refused ? [[]] : clickExpectation(element)))
    }

    // Three elements by their fake names, picked the same way every run.
    var rng = ReplyParserFuzzTests.Seeded(state: stableSeed(name))
    let named = unique.filter { $0.label.hasPrefix("Lorem ") }
    for element in named.shuffled(using: &rng).prefix(3) {
      cases.append(
        Case(
          id: "\(name)-click-\(element.id)", said: "Click on \(element.label)", context: context,
          expect: clickExpectation(element)))
    }

    // Its search field, if it lists one: focused (or pressed open), then
    // typed in — finished by return or a Search button; or, in a browser,
    // a web search.
    if let search = context.elements.first(where: { $0.kind == "search field" }) {
      let typed = "type \"budget\""
      var plans: [[String]] = [
        ["focus #\(search.id) *", typed, "shortcut return"], ["focus #\(search.id) *", typed],
        ["focus #\(search.id) *", typed, "press * \"Search\")"], ["press #\(search.id) *", typed, "shortcut return"],
        ["press * \"Search\")", typed, "shortcut return"], ["press * \"Search\")", typed],
      ]
      // Or the app's own find or search shortcut, then the words.
      for keys in ["cmd+f", "option+cmd+f", "shift+cmd+f", "cmd+k"] {
        plans += [["shortcut \(keys)", typed, "shortcut return"], ["shortcut \(keys)", typed]]
      }
      if ["Google Chrome", "Safari"].contains(context.appName) {
        plans.append(["open_url https://www.google.com/search?q=budget"])
      }
      cases.append(Case(id: "\(name)-search", said: "Search for budget", context: context, expect: plans))
    }
    return cases
  }

  /// A press of the element, or a select of it: a select of something
  /// that isn't a row is carried out as a press.
  static func clickExpectation(_ element: ScreenContext.Element) -> [[String]] {
    [["press #\(element.id) *"], ["select #\(element.id) *"]]
  }

  /// A seed from a name that's the same on every run (`hashValue` isn't).
  static func stableSeed(_ name: String) -> UInt64 {
    name.utf8.reduce(1_469_598_103_934_665_603) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
  }
}

@Suite("Planner eval · recorded screens")
struct PlannerScreenEvalTests {
  @Test("every recording yields cases, each naming an element its screen lists")
  func generated() throws {
    let cases = try PlannerEval.screenCases()
    #expect(Set(cases.map(\.id)).count == cases.count)
    for name in RecordedNode.recordings {
      #expect(cases.filter { $0.id.hasPrefix("\(name)-") }.count >= 3, "\(name) yields too few cases")
    }
    for item in cases {
      #expect(item.unlistedLines.isEmpty, "\(item.id): \(item.unlistedLines)")
    }
    // The same cases every run: the seed is the recording's name.
    #expect(try PlannerEval.screenCases().map(\.id) == cases.map(\.id))
  }
}

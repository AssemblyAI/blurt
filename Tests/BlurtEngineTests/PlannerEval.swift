import Foundation
import Testing

@testable import AssemblyAI
@testable import BlurtEngine

/// The eval's corpus, scoring and run, apart from the tests that drive them.
enum PlannerEval {
  struct Corpus: Decodable {
    enum CodingKeys: String, CodingKey, CaseIterable {
      case passFloor, cases
    }

    /// Every key the corpus file may hold, at any depth: what it and its cases decode.
    static var keys: Set<String> {
      Set(CodingKeys.allCases.map(\.stringValue)).union(Case.CodingKeys.allCases.map(\.stringValue))
    }

    static let url = TestFixtures.url("evals/command-planner/cases.json")

    let passFloor: Double
    let cases: [Case]

    static func load() throws -> Self {
      try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
  }

  /// One spoken command over one screen, and the plans that would do it.
  /// A plan line is a step as the command log writes it (`logLine`), matched
  /// case-insensitively with `*` for any run of characters; an empty plan
  /// is a refusal — the planner answering that it can't, or won't.
  struct Case: Decodable {
    enum CodingKeys: String, CodingKey, CaseIterable {
      case id, said, app, window, incomplete, elements, expect, forbid, screen
    }

    /// An element as the corpus writes it, `[id, kind, label]`.
    private struct Listed: Decodable {
      let element: ScreenContext.Element

      init(from decoder: any Decoder) throws {
        var row = try decoder.unkeyedContainer()
        element = .init(
          id: try row.decode(Int.self), kind: try row.decode(String.self), label: try row.decode(String.self)
        )
      }
    }

    let id: String
    let said: String
    let context: ScreenContext
    let expect: [[String]]
    let forbid: [String]

    var expectsRefusal: Bool { expect.contains([]) }

    /// The expected lines naming an element number its screen doesn't list.
    var unlistedLines: [String] {
      let listed = Set(context.elements.map(\.id))
      return expect.joined().filter { line in
        line.split(separator: " ").contains { word in
          word.hasPrefix("#") && Int(word.dropFirst().prefix(while: \.isNumber)).map { !listed.contains($0) } == true
        }
      }
    }

    /// The app it's scored under: the web app its window is (Google Docs),
    /// else the app in front.
    var app: String {
      AppNotes.notes(for: "", in: context).first?.names.first ?? context.appName ?? "-"
    }

    init(
      id: String,
      said: String,
      app: String,
      expect: [[String]],
      window: String? = nil,
      elements: [ScreenContext.Element] = [],
      forbid: [String] = []
    ) {
      self.id = id
      self.said = said
      context = ScreenContext(appName: app, windowTitle: window, elements: elements)
      self.expect = expect
      self.forbid = forbid
    }

    /// A case over a recorded screen (`RecordedNode.context`), built in code.
    init(id: String, said: String, context: ScreenContext, expect: [[String]], forbid: [String] = []) {
      self.id = id
      self.said = said
      self.context = context
      self.expect = expect
      self.forbid = forbid
    }

    init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      id = try container.decode(String.self, forKey: .id)
      said = try container.decode(String.self, forKey: .said)
      // A recorded screen (`Tests/ScreenTrees`), or one written in the case.
      if let screen = try container.decodeIfPresent(String.self, forKey: .screen) {
        context = try RecordedNode.context(screen)
      } else {
        let elements = try container.decodeIfPresent([Listed].self, forKey: .elements) ?? []
        context = ScreenContext(
          appName: try container.decode(String.self, forKey: .app),
          windowTitle: try container.decodeIfPresent(String.self, forKey: .window),
          elements: elements.map(\.element),
          incomplete: try container.decodeIfPresent(Bool.self, forKey: .incomplete) ?? false
        )
      }
      expect = try container.decode([[String]].self, forKey: .expect)
      forbid = try container.decodeIfPresent([String].self, forKey: .forbid) ?? []
    }

    /// Case-insensitive, with `*` the only special character: a `?` or a
    /// backslash in a typed text is itself.
    static func matches(_ line: String, _ pattern: String) -> Bool {
      let parts = pattern.lowercased().split(separator: "*", omittingEmptySubsequences: false)
      var rest = Substring(line.lowercased())
      guard let first = parts.first, rest.hasPrefix(first) else {
        return false
      }
      rest = rest.dropFirst(first.count)
      guard parts.count > 1, let last = parts.last else {
        return rest.isEmpty
      }
      for part in parts.dropFirst().dropLast() {
        guard let found = rest.range(of: part) else {
          return false
        }
        rest = rest[found.upperBound...]
      }
      return rest.hasSuffix(last)
    }

    func score(_ planned: Result<[VoiceCommandStep], any Error>) -> Verdict {
      let lines: [String]
      switch planned {
      case .success(let steps):
        lines = steps.map { $0.logLine(in: context) }

      case .failure(VoiceCommandError.notUnderstood), .failure(VoiceCommandError.refused):
        lines = []

      case .failure(let error):
        return Verdict(id: id, app: app, passed: false, got: ["error: \(error)"])
      }
      let accepted = expect.contains { plan in
        plan.count == lines.count && zip(plan, lines).allSatisfy { Self.matches($1, $0) }
      }
      let forbidden = lines.contains { line in forbid.contains { Self.matches(line, $0) } }
      return Verdict(id: id, app: app, passed: accepted && !forbidden, got: lines)
    }
  }

  struct Verdict: Encodable {
    let id: String
    /// The app it's scored under: its note's, else the app in front.
    var app = ""
    let passed: Bool
    let got: [String]
  }

  struct Report: Encodable {
    let model: String
    let promptVersion: String
    let passed: Int
    let total: Int
    let verdicts: [Verdict]

    var passRate: Double { total == 0 ? 0 : Double(passed) / Double(total) }

    var summary: String {
      let failures = verdicts.filter { !$0.passed }.map { "  ✗ \($0.id): \($0.got.joined(separator: " ; "))" }
      let apps = Dictionary(grouping: verdicts, by: \.app)
        .sorted { $0.key < $1.key }
        .map { "\($0.key) \($0.value.count { $0.passed })/\($0.value.count)" }
        .joined(separator: ", ")
      return
        (["planner eval \(model) prompt \(promptVersion): PASSED=\(passed)/\(total)", "  by app: \(apps)"] + failures)
        .joined(separator: "\n")
    }

    func json() throws -> Data {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      return try encoder.encode(self)
    }
  }

  /// One case's plan. A gateway that's throttling (429) is waited out and
  /// asked again, up to four times: the eval measures the planner, not the
  /// gateway's rate limit.
  static func plan(_ item: Case, with planner: any VoiceCommandPlanning) async -> Result<[VoiceCommandStep], any Error>
  {
    for attempt in 1...4 {
      do {
        return .success(try await planner.plan(item.said, context: item.context, trace: PlanTrace()))
      } catch GatewayChatError.status(429) where attempt < 4 {
        // wall-clock-ok: backs off from the real gateway's rate limit
        try? await Task.sleep(for: .seconds(5 * attempt))
      } catch {
        return .failure(error)
      }
    }
    return .failure(GatewayChatError.status(429))
  }

  /// Every case planned `runs` times, four requests at a time, and scored.
  static func run(_ cases: [Case], runs: Int, planner: any VoiceCommandPlanning) async -> Report {
    var verdicts: [Verdict] = []
    await withTaskGroup(of: Verdict.self) { group in
      var pending = ArraySlice(Array(repeating: cases, count: max(runs, 1)).flatMap(\.self))
      func next() {
        guard let item = pending.popFirst() else {
          return
        }
        group.addTask {
          item.score(await plan(item, with: planner))
        }
      }
      for _ in 0..<4 { next() }
      for await verdict in group {
        verdicts.append(verdict)
        next()
      }
    }
    let order = Dictionary(cases.enumerated().map { ($1.id, $0) }) { first, _ in first }
    verdicts.sort { order[$0.id, default: 0] < order[$1.id, default: 0] }
    return Report(
      model: VoiceCommandPlanner.model,
      promptVersion: VoiceCommandPlanner.promptVersion,
      passed: verdicts.count { $0.passed },
      total: verdicts.count,
      verdicts: verdicts
    )
  }
}

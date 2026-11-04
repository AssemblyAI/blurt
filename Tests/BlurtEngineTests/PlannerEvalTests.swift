import Foundation
import Testing

@testable import BlurtEngine

/// The Control Your Mac planner's eval: `evals/command-planner/cases.json`,
/// each a spoken command and the screen it was said over, scored on the plan
/// the real planner — instruction, schema, parser — makes of it. The corpus
/// and the scoring are checked on every run; the planning itself costs model
/// calls, so it runs only when asked (`BLURT_PLANNER_EVAL=1`; which cases,
/// `BLURT_PLANNER_EVAL_SET=corpus|screens|all`, all by default) — each case
/// `BLURT_PLANNER_EVAL_RUNS` times (3 unless set), since the gateway's model
/// doesn't answer the same twice even at temperature 0.
@Suite("Planner eval")
struct PlannerEvalTests {
  @Test("the corpus is well formed: unique ids, every element a plan names is listed, refusals included")
  func corpus() throws {
    let corpus = try PlannerEval.Corpus.load()
    #expect(corpus.cases.count >= 20)
    #expect(Set(corpus.cases.map(\.id)).count == corpus.cases.count)
    #expect((0.5...1).contains(corpus.passFloor))
    #expect(corpus.cases.contains { $0.expectsRefusal })
    for item in corpus.cases {
      #expect(!item.expect.isEmpty, "\(item.id) accepts no plan")
      #expect(item.unlistedLines.isEmpty, "\(item.id): \(item.unlistedLines) names an element not listed")
    }
  }

  @Test("a plan passes when it matches an accepted one line for line, and nothing it does is forbidden")
  func scoring() throws {
    let item = PlannerEval.Case(
      id: "t", said: "Click reply.", app: "Mail", elements: [.init(id: 2, kind: "button", label: "Reply")],
      expect: [["press #2*"], ["press_button \"Reply\""]], forbid: ["open_app Terminal"])
    #expect(item.score(.success([.pressElement(2)])).passed)
    #expect(item.score(.success([.pressButton("reply")])).passed)
    #expect(!item.score(.success([.pressElement(2), .media(.mute)])).passed)
    #expect(!item.score(.success([.openApp("Terminal")])).passed)
    #expect(!item.score(.failure(VoiceCommandError.notUnderstood)).passed)
    let refusal = PlannerEval.Case(id: "r", said: "Empty the trash.", app: "Finder", expect: [[]])
    #expect(refusal.score(.failure(VoiceCommandError.notUnderstood)).passed)
    #expect(refusal.score(.failure(VoiceCommandError.refused("press Empty Trash"))).passed)
    // A reply that doesn't parse is the planner failing, never a refusal.
    #expect(!refusal.score(.failure(VoiceCommandError.malformedReply)).passed)
    #expect(!refusal.score(.success([.media(.mute)])).passed)

    #expect(PlannerEval.Case.matches("menu File › Export To › PDF…", "menu file › export* pdf*"))
    #expect(PlannerEval.Case.matches(#"type "What time is it?""#, #"type "what time is it?""#))
    #expect(!PlannerEval.Case.matches(#"type "What time is itX""#, #"type "what time is it?""#))
    #expect(PlannerEval.Case.matches(#"type "C:\temp""#, #"type "c:\temp""#))
    #expect(!PlannerEval.Case.matches("press #12 (button)", "press #1"))
  }

  @Test(
    "the live planner clears the corpus's pass floor",
    .enabled(
      if: ProcessInfo.processInfo.environment["BLURT_PLANNER_EVAL"] == "1",
      "set BLURT_PLANNER_EVAL=1 and ASSEMBLYAI_API_KEY to run (paid model calls)"))
  func live() async throws {
    let environment = ProcessInfo.processInfo.environment
    let key = try #require(environment["ASSEMBLYAI_API_KEY"], "ASSEMBLYAI_API_KEY is not set")
    let corpus = try PlannerEval.Corpus.load()
    let runs = environment["BLURT_PLANNER_EVAL_RUNS"].flatMap(Int.init) ?? 3
    // Which cases: the corpus, the ones generated over recorded screens, or both.
    let set = environment["BLURT_PLANNER_EVAL_SET"] ?? "all"
    let cases =
      (set == "screens" ? [] : corpus.cases) + (set == "corpus" ? [] : try PlannerEval.screenCases())
    let report = await PlannerEval.run(cases, runs: runs, planner: VoiceCommandPlanner(apiKeyProvider: { key }))
    print(report.summary)
    if let out = environment["BLURT_PLANNER_EVAL_OUT"] {
      try report.json().write(to: URL(fileURLWithPath: out))
    }
    #expect(report.passRate >= corpus.passFloor, "\(report.summary)")
  }
}

/// The eval's corpus, scoring and run, apart from the tests that drive them.
enum PlannerEval {
  struct Corpus: Decodable {
    let passFloor: Double
    let cases: [Case]

    static let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("evals/command-planner/cases.json")

    static func load() throws -> Corpus {
      try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: url))
    }
  }

  /// One spoken command over one screen, and the plans that would do it.
  /// A plan line is a step as the command log writes it (`logLine`), matched
  /// case-insensitively with `*` for any run of characters; an empty plan
  /// is a refusal — the planner answering that it can't, or won't.
  struct Case: Decodable {
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
          word.hasPrefix("#") && Int(word.dropFirst().prefix { $0.isNumber }).map { !listed.contains($0) } == true
        }
      }
    }

    /// The app it's scored under: the web app its window is (Google Docs),
    /// else the app in front.
    var app: String {
      AppNotes.notes(for: "", in: context).first?.names.first ?? context.appName ?? "-"
    }

    init(
      id: String, said: String, app: String, window: String? = nil, elements: [ScreenContext.Element] = [],
      expect: [[String]], forbid: [String] = []
    ) {
      self.id = id
      self.said = said
      context = ScreenContext(appName: app, windowTitle: window, elements: elements)
      self.expect = expect
      self.forbid = forbid
    }

    private enum CodingKeys: String, CodingKey {
      case id, said, app, window, incomplete, elements, expect, forbid, screen
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
          incomplete: try container.decodeIfPresent(Bool.self, forKey: .incomplete) ?? false)
      }
      expect = try container.decode([[String]].self, forKey: .expect)
      forbid = try container.decodeIfPresent([String].self, forKey: .forbid) ?? []
    }

    /// An element as the corpus writes it, `[id, kind, label]`.
    private struct Listed: Decodable {
      let element: ScreenContext.Element

      init(from decoder: any Decoder) throws {
        var row = try decoder.unkeyedContainer()
        element = .init(
          id: try row.decode(Int.self), kind: try row.decode(String.self), label: try row.decode(String.self))
      }
    }

    func score(_ planned: Result<[VoiceCommandStep], any Error>) -> Verdict {
      let lines: [String]
      switch planned {
      case .success(let steps): lines = steps.map { $0.logLine(in: context) }
      case .failure(VoiceCommandError.notUnderstood), .failure(VoiceCommandError.refused): lines = []
      case .failure(let error): return Verdict(id: id, app: app, passed: false, got: ["error: \(error)"])
      }
      let accepted = expect.contains { plan in
        plan.count == lines.count && zip(plan, lines).allSatisfy { Self.matches($1, $0) }
      }
      let forbidden = lines.contains { line in forbid.contains { Self.matches(line, $0) } }
      return Verdict(id: id, app: app, passed: accepted && !forbidden, got: lines)
    }

    /// Case-insensitive, with `*` the only special character: a `?` or a
    /// backslash in a typed text is itself.
    static func matches(_ line: String, _ pattern: String) -> Bool {
      let parts = pattern.lowercased().split(separator: "*", omittingEmptySubsequences: false)
      var rest = Substring(line.lowercased())
      guard let first = parts.first, rest.hasPrefix(first) else { return false }
      rest = rest.dropFirst(first.count)
      guard parts.count > 1, let last = parts.last else { return rest.isEmpty }
      for part in parts.dropFirst().dropLast() {
        guard let found = rest.range(of: part) else { return false }
        rest = rest[found.upperBound...]
      }
      return rest.hasSuffix(last)
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
      let apps = Dictionary(grouping: verdicts, by: \.app).sorted { $0.key < $1.key }
        .map { "\($0.key) \($0.value.count { $0.passed })/\($0.value.count)" }.joined(separator: ", ")
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
      } catch ReadAloudLLMError.status(429) where attempt < 4 {
        try? await Task.sleep(for: .seconds(5 * attempt))
      } catch {
        return .failure(error)
      }
    }
    return .failure(ReadAloudLLMError.status(429))
  }

  /// Every case planned `runs` times, four requests at a time, and scored.
  static func run(_ cases: [Case], runs: Int, planner: any VoiceCommandPlanning) async -> Report {
    var verdicts: [Verdict] = []
    await withTaskGroup(of: Verdict.self) { group in
      var pending = ArraySlice(Array(repeating: cases, count: max(runs, 1)).flatMap { $0 })
      func next() {
        guard let item = pending.popFirst() else { return }
        group.addTask {
          return item.score(await plan(item, with: planner))
        }
      }
      for _ in 0..<4 { next() }
      for await verdict in group {
        verdicts.append(verdict)
        next()
      }
    }
    let order = Dictionary(cases.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
    verdicts.sort { order[$0.id, default: 0] < order[$1.id, default: 0] }
    return Report(
      model: VoiceCommandPlanner.model, promptVersion: VoiceCommandPlanner.promptVersion,
      passed: verdicts.count { $0.passed }, total: verdicts.count, verdicts: verdicts)
  }
}

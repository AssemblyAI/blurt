import Foundation
import Testing

@testable import BlurtAssemblyAI
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
    let someRefusal = corpus.cases.contains(where: \.expectsRefusal)
    #expect(someRefusal)
    for item in corpus.cases {
      #expect(!item.expect.isEmpty, "\(item.id) accepts no plan")
      #expect(item.unlistedLines.isEmpty, "\(item.id): \(item.unlistedLines) names an element not listed")
    }
  }

  @Test("the corpus — drafted from real command logs — holds nothing personal, under only the fields it decodes")
  func corpusIsAnonymous() throws {
    let raw = try String(contentsOf: PlannerEval.Corpus.url, encoding: .utf8)
    let found = try TestFixtures.audit(raw, shapes: TestFixtures.personalShapes, allowedKeys: PlannerEval.Corpus.keys)
    #expect(found.isEmpty, "\(found)")
  }

  @Test("a plan passes when it matches an accepted one line for line, and nothing it does is forbidden")
  func scoring() {
    let item = PlannerEval.Case(
      id: "t",
      said: "Click reply.",
      app: "Mail",
      expect: [["press #2*"], ["press_button \"Reply\""]],
      elements: [.init(id: 2, kind: "button", label: "Reply")],
      forbid: ["open_app Terminal"]
    )
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
      "set BLURT_PLANNER_EVAL=1 and ASSEMBLYAI_API_KEY to run (paid model calls)"
    ))
  func live() async throws {
    let environment = ProcessInfo.processInfo.environment
    let key = try #require(environment["ASSEMBLYAI_API_KEY"], "ASSEMBLYAI_API_KEY is not set")
    let corpus = try PlannerEval.Corpus.load()
    let runs = environment["BLURT_PLANNER_EVAL_RUNS"].flatMap(Int.init) ?? 3
    // Which cases: the corpus, the ones generated over recorded screens, or both.
    let set = environment["BLURT_PLANNER_EVAL_SET"] ?? "all"
    let cases =
      (set == "screens" ? [] : corpus.cases) + (set == "corpus" ? [] : try PlannerEval.screenCases())
    let report = await PlannerEval.run(cases, runs: runs, planner: VoiceCommandPlanner { key })
    print(report.summary)
    if let out = environment["BLURT_PLANNER_EVAL_OUT"] {
      try report.json().write(to: URL(fileURLWithPath: out))
    }
    #expect(report.passRate >= corpus.passFloor, "\(report.summary)")
  }
}

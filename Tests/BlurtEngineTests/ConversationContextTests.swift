import Testing

@testable import BlurtEngine

/// The context→turns contract. `turns` reads exactly two fields of the context —
/// `recentTranscripts` and `priorText` — so these cases are as much about what
/// the request *omits* as what it carries; the scope suite below pins the
/// omissions signal by signal.
@Suite("ConversationContext")
struct ConversationContextTests {
  /// One `turns(context:)` expectation. Parameterizing these (rather than a
  /// `@Test` apiece) keeps the whole context→turns contract in one readable table
  /// and gives per-case failure output.
  struct Case: Sendable, CustomTestStringConvertible {
    let name: String
    let context: TranscriptionContext?
    let expected: [String]
    var testDescription: String { name }
  }

  static let cases: [Case] = [
    Case(name: "nil context → no turns", context: nil, expected: []),
    Case(
      name: "empty context → no turns",
      context: TranscriptionContext(appName: nil, priorText: nil), expected: []),
    Case(
      name: "whitespace-only prior text → no turns",
      context: TranscriptionContext(appName: nil, priorText: "  \n\t"), expected: []),
    Case(
      name: "prior text alone → one turn, verbatim",
      context: TranscriptionContext(appName: nil, priorText: "and then the build finished"),
      expected: ["and then the build finished"]),
    Case(
      name: "prior text is trimmed",
      context: TranscriptionContext(appName: nil, priorText: "  hello  "),
      expected: ["hello"]),
    Case(
      name: "newlines inside the prior chunk are preserved",
      context: TranscriptionContext(appName: nil, priorText: "Dear Sam,\n\nthanks for"),
      expected: ["Dear Sam,\n\nthanks for"]),
    Case(
      name: "recent dictations alone → the history, oldest first",
      context: TranscriptionContext(
        appName: nil, priorText: nil, recentTranscripts: ["First one.", "Second one."]),
      expected: ["First one.", "Second one."]),
    Case(
      name: "history then prior chunk — the prior chunk is last",
      context: TranscriptionContext(
        appName: nil, priorText: "thanks for", recentTranscripts: ["First one."]),
      expected: ["First one.", "thanks for"]),
    Case(
      name: "blank history entries are dropped, not sent as empty turns",
      context: TranscriptionContext(
        appName: nil, priorText: nil, recentTranscripts: ["real", "   ", "\n", "also real"]),
      expected: ["real", "also real"]),
    Case(
      name: "every other signal, no history and no prior text → no turns",
      context: TranscriptionContext(
        appName: "Slack", windowTitle: "#eng-backend", fieldLabel: "Message",
        priorText: nil, selectedText: "the draft", keyTerms: ["Blurt"]),
      expected: []),
  ]

  @Test("turns maps the history and the prior chunk to ordered context", arguments: cases)
  func turns(_ c: Case) {
    #expect(ConversationContext.turns(context: c.context) == c.expected)
  }

  @Test("the newest recentTurnCap dictations are kept, the older ones dropped")
  func capsTheHistoryToTheTurnCap() {
    // One over the cap, so the oldest falls off and the count lands exactly on it.
    // The cap is 99, not 100, because `priorText` takes the API's last turn slot —
    // asserted directly below.
    let history = (1...(ConversationContext.recentTurnCap + 1)).map { "utterance \($0)" }
    let turns = ConversationContext.turns(
      context: TranscriptionContext(appName: nil, priorText: nil, recentTranscripts: history))
    #expect(turns.count == ConversationContext.recentTurnCap)
    #expect(turns.first == "utterance 2")  // "utterance 1" was the oldest
    #expect(turns.last == history.last)
  }

  @Test("a full history plus a prior chunk is exactly the API's 100-turn maximum")
  func fullHistoryPlusPriorFitsTheTurnMaximum() {
    // The whole reason `recentTurnCap` is 99: the request must never ask for a
    // 101st turn, and the prior chunk is the turn that has to survive.
    let history = (1...200).map { "u\($0)" }
    let turns = ConversationContext.turns(
      context: TranscriptionContext(
        appName: nil, priorText: "at the cursor", recentTranscripts: history))
    #expect(turns.count == 100)
    #expect(turns.last == "at the cursor")
  }

  @Test("an over-long history is fitted to the character cap, keeping the newest")
  func fitsTheCharacterCapKeepingTheNewest() {
    // 40 turns of ~200 characters is well past 4096, so most must go. The server
    // would drop the oldest itself; doing it here keeps the request small and
    // makes which end survives a tested decision rather than a remote one.
    // No trailing space on a turn: every kept turn is trimmed, so a fixture that
    // ended in one would differ from its own expectation for an unrelated reason.
    let history = (1...40).map { "\($0) " + String(repeating: "word ", count: 39) + "word" }
    let turns = ConversationContext.turns(
      context: TranscriptionContext(appName: nil, priorText: nil, recentTranscripts: history))
    #expect(turns.map(\.count).reduce(0, +) <= ConversationContext.characterCap)
    // A contiguous newest run: the last turn is the newest, and no older turn was
    // skipped to squeeze a shorter one in behind it.
    #expect(turns.last == history.last)
    #expect(turns == Array(history.suffix(turns.count)))
  }

  @Test("a single over-long turn is clipped to the cap, keeping its tail")
  func clipsOneHugeTurnToTheCap() throws {
    // `FocusCapture` clips far shorter than this, but the cap is enforced here
    // rather than assumed of the caller. The *tail* is what survives: the
    // utterance continues from the text nearest the cursor, so the oldest end is
    // the part worth losing. Dropping the turn instead would send no context at
    // all, which is strictly worse.
    let longPrior = String(repeating: "word ", count: 2000) + "end"
    let turns = ConversationContext.turns(
      context: TranscriptionContext(appName: nil, priorText: longPrior))
    let only = try #require(turns.first)
    #expect(turns.count == 1)
    #expect(only.count == ConversationContext.characterCap)
    #expect(only.hasSuffix("end"))
  }

  @Test("an older turn that doesn't fit is dropped whole, never half-sent")
  func doesNotClipOlderTurns() {
    // Half a sentence read as a complete turn is worse than a shorter dialogue:
    // the model would take the truncation for how the speaker actually talks.
    // Sized so the two newer turns fit and this one cannot: 4090 + 6 + 6 > 4096.
    let old = String(repeating: "a", count: ConversationContext.characterCap - 6)
    let turns = ConversationContext.turns(
      context: TranscriptionContext(
        appName: nil, priorText: "newest", recentTranscripts: [old, "middle"]))
    #expect(turns == ["middle", "newest"])
  }
}

/// What the context is *not* allowed to carry. Every signal below is captured at
/// press time and kept on the machine: the focus fields drive the paste path
/// (the leading separator, the injector's window identity) and the developer-mode
/// log, and the key terms ride their own request field (`KeytermsBoost`) rather
/// than this one. `turns` is the only door to the wire, so this suite is what
/// stands between a captured context and AssemblyAI's servers.
@Suite("ConversationContext scope")
struct ConversationContextScopeTests {
  /// The richest context the capture path can produce — every signal populated.
  private let context = TranscriptionContext(
    appName: "Slack", windowTitle: "#eng-backend", fieldLabel: "Message",
    priorText: "thanks for", selectedText: "the draft",
    recentTranscripts: ["Shipping the release notes now."], keyTerms: ["Blurt"])

  @Test(
    "no local-only signal reaches the wire",
    arguments: ["Slack", "#eng-backend", "Message", "the draft", "Blurt"])
  func signalStaysLocal(_ signal: String) {
    #expect(!ConversationContext.turns(context: context).contains { $0.contains(signal) })
  }

  @Test("the turns are exactly the history then the prior chunk")
  func turnsAreHistoryThenPriorChunk() {
    // Pinned whole, not just signal by signal: a new field appended to the turn
    // list would pass every containment check above and fail here.
    #expect(
      ConversationContext.turns(context: context)
        == ["Shipping the release notes now.", "thanks for"])
  }
}

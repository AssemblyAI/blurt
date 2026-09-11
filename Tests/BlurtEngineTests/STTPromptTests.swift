import Testing

@testable import BlurtEngine

/// The context→prompt contract. `text` reads exactly two fields of the context —
/// `recentTranscripts` and `priorText` — so these cases are as much about what
/// the request *omits* as what it carries; the scope suite below pins the
/// omissions signal by signal.
@Suite("STTPrompt")
struct STTPromptTests {
  /// One `text(context:)` expectation. Parameterizing these (rather than a
  /// `@Test` apiece) keeps the whole context→prompt contract in one readable table
  /// and gives per-case failure output.
  struct Case: Sendable, CustomTestStringConvertible {
    let name: String
    let context: TranscriptionContext?
    let expected: String
    var testDescription: String { name }
  }

  static let cases: [Case] = [
    Case(name: "nil context → no prompt", context: nil, expected: ""),
    Case(
      name: "empty context → no prompt",
      context: TranscriptionContext(appName: nil, priorText: nil), expected: ""),
    Case(
      name: "whitespace-only prior text → no prompt",
      context: TranscriptionContext(appName: nil, priorText: "  \n\t"), expected: ""),
    Case(
      name: "prior text alone → that text, verbatim",
      context: TranscriptionContext(appName: nil, priorText: "and then the build finished"),
      expected: "and then the build finished"),
    Case(
      name: "prior text is trimmed",
      context: TranscriptionContext(appName: nil, priorText: "  hello  "),
      expected: "hello"),
    Case(
      name: "newlines inside the prior chunk are preserved",
      context: TranscriptionContext(appName: nil, priorText: "Dear Sam,\n\nthanks for"),
      expected: "Dear Sam,\n\nthanks for"),
    Case(
      name: "recent dictations alone → the history, oldest first",
      context: TranscriptionContext(
        appName: nil, priorText: nil, recentTranscripts: ["First one.", "Second one."]),
      expected: "First one.\nSecond one."),
    Case(
      name: "history then prior chunk — the prior chunk is last",
      context: TranscriptionContext(
        appName: nil, priorText: "thanks for", recentTranscripts: ["First one."]),
      expected: "First one.\nthanks for"),
    Case(
      name: "blank history entries are dropped, not joined as empty lines",
      context: TranscriptionContext(
        appName: nil, priorText: nil, recentTranscripts: ["real", "   ", "\n", "also real"]),
      expected: "real\nalso real"),
    Case(
      name: "every other signal, no history and no prior text → no prompt",
      context: TranscriptionContext(
        appName: "Slack", windowTitle: "#eng-backend", fieldLabel: "Message",
        priorText: nil, selectedText: "the draft", keyTerms: ["Blurt"]),
      expected: ""),
  ]

  @Test("text maps the history and the prior chunk to one ordered prompt", arguments: cases)
  func text(_ c: Case) {
    #expect(STTPrompt.text(context: c.context) == c.expected)
  }

  @Test("history a prior chunk already carries is not sent twice")
  func dedupesHistoryAlreadyInThePriorChunk() {
    // The ordinary continuous-dictation case: dictation 1 pasted "Let's ship
    // Friday." into the composer, so press 2 reads it back as the prior chunk while
    // it is also the newest history entry. Sent as both, the model sees one
    // utterance twice over.
    let context = TranscriptionContext(
      appName: "Slack", priorText: "Let's ship Friday. ",
      recentTranscripts: ["Morning all.", "Let's ship Friday."])
    #expect(STTPrompt.text(context: context) == "Morning all.\nLet's ship Friday.")
  }

  @Test("a whole run of dictations into one field collapses, not just the last")
  func dedupesEveryTurnThePriorChunkCarries() {
    // Three dictations into the same composer: the prior chunk is all three, so all
    // three history entries are already spoken for.
    let context = TranscriptionContext(
      appName: "Slack", priorText: "One. Two. Three.",
      recentTranscripts: ["Older elsewhere.", "One.", "Two.", "Three."])
    #expect(STTPrompt.text(context: context) == "Older elsewhere.\nOne. Two. Three.")
  }

  @Test("dedupe stops at the first entry the prior chunk doesn't carry")
  func dedupeStopsAtAnInterruptedRun() {
    // The user typed, or moved to another field, between dictations: only the tail
    // of the run is in the chunk, and everything before it is genuine history the
    // chunk cannot speak for — including text that appears earlier in the field.
    let context = TranscriptionContext(
      appName: "Slack", priorText: "Two. typed by hand. Three.",
      recentTranscripts: ["Two.", "Three."])
    #expect(STTPrompt.text(context: context) == "Two.\nTwo. typed by hand. Three.")
  }

  @Test("history that merely resembles the prior chunk is still sent")
  func keepsHistoryThatIsNotASuffix() {
    // Suffix, not "contains": text the user dictated earlier and that happens to
    // appear mid-field is not what this utterance continues from.
    let context = TranscriptionContext(
      appName: "Slack", priorText: "Ship it. Then follow up.",
      recentTranscripts: ["Ship it."])
    #expect(STTPrompt.text(context: context) == "Ship it.\nShip it. Then follow up.")
  }

  @Test("a history deeper than the cap is fitted, keeping the newest")
  func fitsTheCharacterCapKeepingTheNewest() {
    // 40 entries of ~200 characters is well past 4096, so most must go. There is no
    // turn cap any more — this budget is the only limit, and unlike the field it
    // replaced the server *rejects* an over-cap prompt instead of trimming it, so
    // getting this wrong is a 400 on every dictation rather than a long request.
    let history = (1...40).map { "\($0) " + String(repeating: "word ", count: 39) + "word" }
    let prompt = STTPrompt.text(
      context: TranscriptionContext(appName: nil, priorText: nil, recentTranscripts: history))
    #expect(prompt.unicodeScalars.count <= STTPrompt.characterCap)
    // A contiguous newest run, separators and all: the newest entry is last, and no
    // older one was skipped to squeeze a shorter one in behind it.
    let kept = prompt.components(separatedBy: STTPrompt.turnSeparator)
    #expect(kept.last == history.last)
    #expect(kept == Array(history.suffix(kept.count)))
  }

  @Test("the whole history goes when it fits, however many entries that is")
  func keepsEveryEntryThatFits() {
    // The removed `recentTurnCap` (99) would have dropped the oldest of these; the
    // 100-turn limit it answered to belonged to `conversation_context` and does not
    // exist on this field. Short entries, so 120 of them fit the scalar budget.
    let history = (1...120).map { "u\($0)" }
    let prompt = STTPrompt.text(
      context: TranscriptionContext(
        appName: nil, priorText: "at the cursor", recentTranscripts: history))
    #expect(prompt.components(separatedBy: STTPrompt.turnSeparator).count == 121)
    #expect(prompt.hasSuffix("\nat the cursor"))
  }

  @Test("the separators are charged against the cap, not sent on top of it")
  func countsSeparatorsAgainstTheCap() {
    // Every join spends a scalar. Entries sized so the text alone is exactly the
    // cap: if the separators rode for free the prompt would go out over it, and the
    // request would 400 before the audio was read.
    let history = (1...64).map { _ in String(repeating: "a", count: 64) }
    let prompt = STTPrompt.text(
      context: TranscriptionContext(appName: nil, priorText: nil, recentTranscripts: history))
    #expect(prompt.unicodeScalars.count <= STTPrompt.characterCap)
  }

  @Test("the cap counts scalars, the unit the server counts")
  func countsScalarsRatherThanGraphemes() {
    // Measured, not inferred: 820 family emoji is 820 grapheme clusters but 4100
    // scalars, and the service rejects it — `stt_prompt: String should have at most
    // 4096 characters`. Swift's `String.count` counts graphemes, so a cap enforced
    // in those units would pass this string straight through to a 400.
    let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"  // 1 grapheme, 5 scalars
    let prompt = STTPrompt.text(
      context: TranscriptionContext(
        appName: nil, priorText: String(repeating: family, count: 820)))
    #expect(prompt.unicodeScalars.count <= STTPrompt.characterCap)
    #expect(prompt.count < STTPrompt.characterCap)  // graphemes alone would have fit
  }

  @Test("a single over-long entry is clipped to the cap, keeping its tail")
  func clipsOneHugeTurnToTheCap() {
    // `FocusCapture` clips far shorter than this, but the cap is enforced here
    // rather than assumed of the caller. The *tail* is what survives: the
    // utterance continues from the text nearest the cursor, so the oldest end is
    // the part worth losing. Dropping it instead would send no context at all,
    // which is strictly worse.
    let longPrior = String(repeating: "word ", count: 2000) + "end"
    let prompt = STTPrompt.text(
      context: TranscriptionContext(appName: nil, priorText: longPrior))
    #expect(prompt.unicodeScalars.count == STTPrompt.characterCap)
    #expect(prompt.hasSuffix("end"))
    #expect(!prompt.contains(STTPrompt.turnSeparator))
  }

  @Test("an older entry that doesn't fit is dropped whole, never half-sent")
  func doesNotClipOlderTurns() {
    // Half a sentence read as continuous text is worse than a shorter prompt: the
    // model would take the truncation for how the speaker actually talks.
    // Sized so the two newer entries fit and this one cannot.
    let old = String(repeating: "a", count: STTPrompt.characterCap - 6)
    let prompt = STTPrompt.text(
      context: TranscriptionContext(
        appName: nil, priorText: "newest", recentTranscripts: [old, "middle"]))
    #expect(prompt == "middle\nnewest")
  }
}

/// What the context is *not* allowed to carry. Every signal below is captured at
/// press time and kept on the machine: the focus fields drive the paste path
/// (the leading separator, the injector's window identity) and the developer-mode
/// log, and the key terms ride their own request field (`KeytermsBoost`) rather
/// than this one. `text` is the only door to the wire, so this suite is what
/// stands between a captured context and AssemblyAI's servers.
@Suite("STTPrompt scope")
struct STTPromptScopeTests {
  /// The richest context the capture path can produce — every signal populated.
  private let context = TranscriptionContext(
    appName: "Slack", windowTitle: "#eng-backend", fieldLabel: "Message",
    priorText: "thanks for", selectedText: "the draft",
    recentTranscripts: ["Shipping the release notes now."], keyTerms: ["Blurt"])

  @Test(
    "no local-only signal reaches the wire",
    arguments: ["Slack", "#eng-backend", "Message", "the draft", "Blurt"])
  func signalStaysLocal(_ signal: String) {
    #expect(!STTPrompt.text(context: context).contains(signal))
  }

  @Test("the prompt is exactly the history then the prior chunk")
  func promptIsHistoryThenPriorChunk() {
    // Pinned whole, not just signal by signal: a new field appended to the prompt
    // would pass every containment check above and fail here.
    #expect(
      STTPrompt.text(context: context) == "Shipping the release notes now.\nthanks for")
  }
}

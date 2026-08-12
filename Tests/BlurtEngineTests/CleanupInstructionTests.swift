import Foundation
import Testing

@testable import BlurtEngine

/// Regression tests for the shipped cleanup instruction. There is no logic to
/// exercise — it's a constant — so these guard the properties a later edit could
/// break silently, on a string that reaches every user's every dictation. The
/// wiring itself (that it lands in `config.llm.instruction`) is asserted in
/// `AssemblyAITranscriberTests`.
@Suite("CleanupInstruction")
struct CleanupInstructionTests {
  /// A blank or padded instruction is the failure with no symptom: the service
  /// would apply whitespace as the whole instruction, and the rewrite that comes
  /// back is whatever an unguided model does with the transcript.
  @Test("the instruction is non-blank and carries no surrounding padding")
  func wellFormed() {
    #expect(CleanupInstruction.text.isEmpty == false)
    #expect(
      CleanupInstruction.text.trimmingCharacters(in: .whitespacesAndNewlines)
        == CleanupInstruction.text)
  }

  /// The one that matters, and the one that was wrong before. `config.llm.instruction`
  /// is capped at 2048 (counted here in UTF-8 bytes — the conservative unit, see
  /// `characterCap`) and the API rejects the whole request above it — a 400 before
  /// the audio is read, so every dictation fails outright rather than degrading to
  /// the verbatim transcript. A 3057-character instruction shipped once and did
  /// exactly that, past a version of this very test that asserted
  /// `TranscriptionPrompt.characterCap` — the 4096 limit on the *other* field.
  ///
  /// So this asserts the instruction's own cap, and the next test pins the two apart.
  @Test("the instruction fits the API's cap on config.llm.instruction")
  func withinCap() {
    #expect(CleanupInstruction.text.utf8.count <= CleanupInstruction.characterCap)
  }

  /// The cap is not only asserted here — `AssemblyAITranscriber` consults it on every
  /// request and omits the instruction if it would not fit, so an over-cap edit
  /// degrades to the service's own default cleanup instead of failing every
  /// dictation. This pins the healthy state: it fits, so it is sent.
  @Test("a fitting instruction is the one actually sent")
  func sendableWhenItFits() {
    #expect(CleanupInstruction.sendable == CleanupInstruction.text)
  }

  /// The mistake was reaching for a nearby constant that happened to be a length.
  /// If these two ever converge, the test above stops distinguishing them.
  @Test("the instruction's cap is not the prompt's cap")
  func capsAreDistinct() {
    #expect(CleanupInstruction.characterCap == 2048)
    #expect(CleanupInstruction.characterCap < TranscriptionPrompt.characterCap)
  }

  /// The product-critical clauses, as opposed to the cleanup quality the eval
  /// measured. Dictating "what time is it?" into a text field must paste that
  /// question back, not an answer to it — an instruction-following model handed a
  /// bare transcript will otherwise treat it as a request. Same for translation:
  /// non-English speech has to survive as spoken.
  ///
  /// The eval cannot defend these. Every corpus behind the instruction is
  /// conversational English between two humans, so an instruction that drops them
  /// scores exactly the same while freeing characters under a cap the optimizer is
  /// pushed to cut toward — which is why `evals/dictation-prompt` gates them too,
  /// and why they are asserted here rather than trusted.
  @Test("the instruction keeps the do-not-answer, do-not-translate, do-not-rephrase safeguards")
  func safeguards() {
    for clause in ["answer the text", "translate", "rephrase"] {
      #expect(CleanupInstruction.text.contains(clause), "missing safeguard: \(clause)")
    }
  }

  /// The append is additive-only: the base instruction leads unchanged (its
  /// safeguards keep protecting every request), the preamble bridges, and the
  /// user's text — trimmed of padding — closes.
  @Test("custom style instructions are appended after the unchanged base instruction")
  func customStyleIsAppended() throws {
    let combined = try #require(CleanupInstruction.sendable(appending: "  always write in lowercase \n"))
    #expect(combined.hasPrefix(CleanupInstruction.text + CleanupInstruction.customStylePreamble))
    #expect(combined.hasSuffix("always write in lowercase"))
    #expect(combined.utf8.count <= CleanupInstruction.characterCap)
  }

  /// Empty must mean "identical to today", not an empty suffix — a trailing
  /// preamble with nothing under it would hand the model a dangling directive.
  @Test(
    "nil and blank custom style leave the sent instruction exactly as shipped",
    arguments: [nil, "", "   \n "])
  func blankCustomStyleChangesNothing(custom: String?) {
    #expect(CleanupInstruction.sendable(appending: custom) == CleanupInstruction.sendable)
  }

  /// The Settings field enforces the budget, but nothing stops a longer string
  /// reaching the defaults slot some other way — and over the cap the API rejects
  /// the whole request, failing every dictation. So the engine trims too.
  @Test("an over-budget custom style is trimmed so the request still fits the cap")
  func overBudgetCustomStyleIsTrimmed() throws {
    let oversized = String(repeating: "x", count: CleanupInstruction.customStyleBudget + 100)
    let combined = try #require(CleanupInstruction.sendable(appending: oversized))
    #expect(combined.utf8.count == CleanupInstruction.characterCap)
    #expect(combined.hasPrefix(CleanupInstruction.text))
  }

  /// Emoji are the worst case the field's placeholder invites: one `Character`
  /// can be many UTF-8 bytes, so a character-counted trim could pass every
  /// client check while the encoded request still trips the server's cap. This
  /// pins the byte-measured trim — and that it drops whole characters, so a
  /// multi-scalar emoji is never split into an invalid fragment.
  @Test("a multi-scalar emoji custom style is trimmed by bytes, on whole characters")
  func emojiCustomStyleFitsTheCapInBytes() throws {
    let emoji = "👩🏽‍💻"  // four scalars, 15 UTF-8 bytes, one Character
    let oversized = String(repeating: emoji, count: CleanupInstruction.customStyleBudget)
    let combined = try #require(CleanupInstruction.sendable(appending: oversized))
    #expect(combined.utf8.count <= CleanupInstruction.characterCap)
    let lead = CleanupInstruction.text + CleanupInstruction.customStylePreamble
    #expect(combined.hasPrefix(lead))
    // Something survived the trim, and only whole emoji did.
    let appended = combined.dropFirst(lead.count)
    #expect(appended.isEmpty == false)
    #expect(appended.allSatisfy { String($0) == emoji })
  }

  /// The budget is derived, not restated — this pins the arithmetic that keeps a
  /// full-length custom style at exactly the cap, and that there is meaningful
  /// room at all (a re-optimized base instruction could quietly eat it).
  @Test("the custom style budget is the real headroom under the cap")
  func customStyleBudgetIsTheHeadroom() {
    #expect(
      CleanupInstruction.text.utf8.count + CleanupInstruction.customStylePreamble.utf8.count
        + CleanupInstruction.customStyleBudget == CleanupInstruction.characterCap)
    #expect(CleanupInstruction.customStyleBudget >= 200)
    #expect(CustomStyleStore.characterLimit == CleanupInstruction.customStyleBudget)
  }

  /// It travels as one JSON string. The instruction is full of quotes, backticks,
  /// em dashes and `→` arrows — the encode has to survive all of them, and
  /// decoding back has to yield the same string rather than a mangled one.
  @Test("the instruction round-trips through JSON unchanged")
  func jsonRoundTrip() throws {
    let encoded = try JSONEncoder().encode(["instruction": CleanupInstruction.text])
    let decoded = try JSONDecoder().decode([String: String].self, from: encoded)
    #expect(decoded["instruction"] == CleanupInstruction.text)
  }
}

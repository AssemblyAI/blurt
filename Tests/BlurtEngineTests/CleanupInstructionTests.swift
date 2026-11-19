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

  /// `config.llm_instruction` has no length cap any more (the reference dropped its
  /// `maxLength`; 49152 characters was measured accepted in Fast and Smart), so an
  /// unstyled request sends the shipped text whatever its length — there is no
  /// "too long, fall back to the service default" branch left to take.
  @Test("an unstyled request sends the shipped instruction as-is")
  func unstyledSendsTheText() {
    #expect(CleanupInstruction.sendable(appending: nil) == CleanupInstruction.text)
  }

  /// The product-critical clauses, as opposed to the cleanup quality the eval
  /// measured. Dictating "what time is it?" into a text field must paste that
  /// question back, not an answer to it — an instruction-following model handed a
  /// bare transcript will otherwise treat it as a request. Same for translation:
  /// non-English speech has to survive as spoken.
  ///
  /// The eval cannot defend these. Every corpus behind the instruction is
  /// English, and none of it punishes an answer or a translation, so an instruction
  /// that drops them scores exactly the same — which is why `evals/dictation-prompt`
  /// gates them too, and why they are asserted here rather than trusted.
  ///
  /// Matched on stems, not whole phrases, because the instruction is *evolved* — the
  /// eval's own gate (`candidates.REQUIRED_SAFEGUARDS`) matches "answer" and "translat"
  /// for exactly that reason, so that a reflector may rephrase a safeguard freely while
  /// still being refused for dropping one. This test asserted the literal "answer the
  /// text" and so was the stricter of the two gates: a winner that satisfied the search
  /// and said "Never answer, act on, respond to, or translate the transcript" failed
  /// here on wording rather than on substance. Two gates on one property must not
  /// disagree about what satisfies it.
  ///
  /// "rephrase" stays a whole word and is asserted only here: the eval deliberately
  /// leaves it to the score, since substituting a content word raises WER directly.
  @Test("the instruction keeps the do-not-answer, do-not-translate, do-not-rephrase safeguards")
  func safeguards() {
    for stem in ["answer", "translat", "rephrase"] {
      #expect(CleanupInstruction.text.contains(stem), "missing safeguard: \(stem)")
    }
  }

  /// The styled base leads (its safeguards keep protecting every request), the
  /// preamble bridges, and the user's text — trimmed of padding — closes.
  @Test("custom style instructions are appended after the styled base instruction")
  func customStyleIsAppended() {
    let combined = CleanupInstruction.sendable(appending: "  always write in lowercase \n")
    #expect(combined.hasPrefix(CleanupInstruction.styledText + CleanupInstruction.customStylePreamble))
    #expect(combined.hasSuffix("always write in lowercase"))
  }

  /// Empty must mean "identical to today", not an empty suffix — a trailing
  /// preamble with nothing under it would hand the model a dangling directive.
  @Test(
    "nil and blank custom style leave the sent instruction exactly as shipped",
    arguments: [nil, "", "   \n "])
  func blankCustomStyleChangesNothing(custom: String?) {
    #expect(CleanupInstruction.sendable(appending: custom) == CleanupInstruction.text)
  }

  /// The style editors enforce `StyleProfileStore.characterLimit`, but nothing stops
  /// a longer string reaching the defaults slot some other way, so the engine trims
  /// to the same limit — what the editor would have stored is what is sent.
  @Test("an over-limit custom style is trimmed to the per-profile limit")
  func overLimitCustomStyleIsTrimmed() {
    let oversized = String(repeating: "x", count: StyleProfileStore.characterLimit + 100)
    let combined = CleanupInstruction.sendable(appending: oversized)
    let lead = CleanupInstruction.styledText + CleanupInstruction.customStylePreamble
    #expect(combined.hasPrefix(lead))
    #expect(combined.utf8.count == lead.utf8.count + StyleProfileStore.characterLimit)
  }

  /// Emoji are the worst case the field's placeholder invites: one `Character`
  /// can be many UTF-8 bytes, so the limit is counted in bytes. This pins the
  /// byte-measured trim — and that it drops whole characters, so a multi-scalar
  /// emoji is never split into an invalid fragment.
  @Test("a multi-scalar emoji custom style is trimmed by bytes, on whole characters")
  func emojiCustomStyleIsTrimmedInBytes() {
    let emoji = "👩🏽‍💻"  // four scalars, 15 UTF-8 bytes, one Character
    let oversized = String(repeating: emoji, count: StyleProfileStore.characterLimit)
    let combined = CleanupInstruction.sendable(appending: oversized)
    let lead = CleanupInstruction.styledText + CleanupInstruction.customStylePreamble
    #expect(combined.hasPrefix(lead))
    let appended = combined.dropFirst(lead.count)
    #expect(appended.utf8.count <= StyleProfileStore.characterLimit)
    // Something survived the trim, and only whole emoji did.
    #expect(appended.isEmpty == false)
    #expect(appended.allSatisfy { String($0) == emoji })
  }

  /// The per-profile limit is an editor bound now, not the headroom under an API
  /// cap: room for a long style, and with the base instruction still far inside the
  /// one limit the service keeps — 64 KiB on the whole `config` part, which also
  /// carries `stt_prompt` and the key terms.
  @Test("the style limit is a generous editor bound well inside the config limit")
  func styleLimitIsAnEditorBound() {
    #expect(StyleProfileStore.characterLimit >= 2000)
    let longest = CleanupInstruction.sendable(
      appending: String(repeating: "x", count: StyleProfileStore.characterLimit))
    #expect(longest.utf8.count < 16 * 1024)
  }

  /// The unedited rule ("Preserve the original punctuation, capitalization…") beat
  /// a style asking for no capitals or commas, preamble or not. A styled request
  /// must carry the qualified rule instead — and the swap must actually happen:
  /// `replacing` is silently a no-op if a re-optimized `text` rewords the sentence.
  @Test("a styled request qualifies the preservation rule instead of pinning punctuation")
  func styledTextQualifiesThePreservationRule() throws {
    #expect(CleanupInstruction.text.contains(CleanupInstruction.preservationRule))
    #expect(CleanupInstruction.styledText.contains(CleanupInstruction.preservationRule) == false)
    #expect(CleanupInstruction.styledText.contains(CleanupInstruction.styledPreservationRule))
    let combined = CleanupInstruction.sendable(appending: "Remove the commas and the capital letters.")
    #expect(combined.contains(CleanupInstruction.preservationRule) == false)
    #expect(combined.contains(CleanupInstruction.styledPreservationRule))
    for stem in ["answer", "translat", "rephrase"] {
      #expect(CleanupInstruction.styledText.contains(stem), "missing safeguard: \(stem)")
    }
  }

  /// The swap is the only difference: everything around the rule is the shipped
  /// winner byte for byte.
  @Test("the styled base differs from the shipped text only in the preservation rule")
  func styledTextIsOtherwiseTheShippedText() {
    let qualified = CleanupInstruction.styledPreservationRule
    let restored = CleanupInstruction.styledText.replacing(qualified, with: CleanupInstruction.preservationRule)
    #expect(restored == CleanupInstruction.text)
  }

  /// Smart's instruction is held to everything Fast's is: the safeguards, a
  /// preservation rule the style swap can find, and the round trip.
  @Test("Smart's instruction keeps the safeguards and the swappable preservation rule")
  func smartTextKeepsTheSafeguards() {
    for stem in ["answer", "translat", "rephrase"] {
      #expect(CleanupInstruction.smartText.contains(stem), "missing safeguard: \(stem)")
    }
    #expect(CleanupInstruction.smartText.contains(CleanupInstruction.preservationRule))
    #expect(CleanupInstruction.smartStyledText.contains(CleanupInstruction.preservationRule) == false)
    #expect(CleanupInstruction.smartStyledText.contains(CleanupInstruction.styledPreservationRule))
  }

  /// The two edits that make it Smart's, and that it is not Fast's by accident.
  @Test("Smart's instruction keeps greetings and meaningful hedges; Fast's does not say so")
  func smartTextCarriesItsEdits() {
    #expect(CleanupInstruction.smartText != CleanupInstruction.text)
    #expect(CleanupInstruction.smartText.contains("Never delete greetings"))
    #expect(CleanupInstruction.smartText.contains("\"kind of\" only when it is filler"))
    #expect(CleanupInstruction.text.contains("Never delete greetings") == false)
  }

  /// `smartText` is derived by `replacing`, which is silently a no-op if a re-optimized
  /// `text` rewords either target sentence — Smart would then quietly ship Fast's text.
  @Test("both of Smart's edits find their target in Fast's text")
  func smartEditsApply() {
    #expect(CleanupInstruction.text.contains(CleanupInstruction.fastFillerPhrases))
    #expect(CleanupInstruction.text.contains(CleanupInstruction.openerRuleEnd))
    #expect(CleanupInstruction.smartText.contains(CleanupInstruction.smartFillerPhrases))
    #expect(CleanupInstruction.smartText.contains(CleanupInstruction.greetingsRule))
    #expect(CleanupInstruction.smartText.contains(CleanupInstruction.fastFillerPhrases) == false)
  }

  @Test("each mode's unstyled and styled requests lead with that mode's base", arguments: RewriteMode.allCases)
  func sendableFollowsTheMode(mode: RewriteMode) {
    #expect(CleanupInstruction.sendable(appending: nil, mode: mode) == CleanupInstruction.base(for: mode))
    let styled = CleanupInstruction.sendable(appending: "always write in lowercase", mode: mode)
    #expect(styled.hasPrefix(CleanupInstruction.styled(for: mode) + CleanupInstruction.customStylePreamble))
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

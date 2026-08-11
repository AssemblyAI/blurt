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
  /// is capped at 2048 characters and the API rejects the whole request above it —
  /// a 400 before the audio is read, so every dictation fails outright rather than
  /// degrading to the verbatim transcript. A 3057-character instruction shipped once
  /// and did exactly that, past a version of this very test that asserted
  /// `TranscriptionPrompt.characterCap` — the 4096 limit on the *other* field.
  ///
  /// So this asserts the instruction's own cap, and the next test pins the two apart.
  @Test("the instruction fits the API's cap on config.llm.instruction")
  func withinCap() {
    #expect(CleanupInstruction.text.count <= CleanupInstruction.characterCap)
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

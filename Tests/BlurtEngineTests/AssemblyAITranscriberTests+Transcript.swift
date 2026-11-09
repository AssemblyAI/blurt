import Foundation
import Testing

@testable import BlurtEngine

/// Which transcript gets pasted: `AssemblyAITranscriber.chooseTranscript`,
/// pure, over the measured shapes of the route's rewrite.
@Suite("AssemblyAITranscriber: which transcript gets pasted")
struct AssemblyAITranscriberTranscriptTests {
  @Test("the rewrite is pasted only over spoken words: no speech means nothing, whatever the model wrote")
  func chooseTranscript() {
    let instruction = "No grammatical fixes ever. Just dictate."
    #expect(AssemblyAITranscriber.chooseTranscript(verbatim: "", rewrite: instruction, enhanced: true) == "")
    #expect(AssemblyAITranscriber.chooseTranscript(verbatim: "  \n", rewrite: instruction, enhanced: true) == "  \n")
    #expect(
      AssemblyAITranscriber.chooseTranscript(verbatim: "hello there", rewrite: "Hello there.", enhanced: true)
        == "Hello there.")
    #expect(
      AssemblyAITranscriber.chooseTranscript(verbatim: "hello there", rewrite: nil, enhanced: true) == "hello there")
    #expect(
      AssemblyAITranscriber.chooseTranscript(verbatim: "hello there", rewrite: " ", enhanced: true) == "hello there")
    #expect(
      AssemblyAITranscriber.chooseTranscript(verbatim: "hello there", rewrite: "Hello there.", enhanced: false)
        == "hello there")
  }

  @Test("a rewrite that reads the instruction back, or says nothing, loses to the verbatim transcript")
  func chooseTranscriptOverAnEcho() throws {
    let style = "No grammatical fixes ever. Just dictate what I say."
    let instruction = try #require(CleanupInstruction.sendable(appending: style))
    // Measured against the route on 2026-11-05: "Yeah." → the style text, "Um." → ".".
    #expect(
      AssemblyAITranscriber.chooseTranscript(
        verbatim: "Yeah.", rewrite: style, enhanced: true, instruction: instruction)
        == "Yeah.")
    #expect(
      AssemblyAITranscriber.chooseTranscript(verbatim: "Um.", rewrite: ".", enhanced: true, instruction: instruction)
        == "Um.")
    #expect(
      AssemblyAITranscriber.chooseTranscript(
        verbatim: "Yeah.", rewrite: "Sure. \(style) Done.", enhanced: true, instruction: instruction) == "Yeah.")
    // Speech is still rewritten, and the switch off still pastes the words as spoken.
    #expect(
      AssemblyAITranscriber.chooseTranscript(
        verbatim: "um so lunch tomorrow works", rewrite: "Lunch tomorrow works.", enhanced: true,
        instruction: instruction) == "Lunch tomorrow works.")
    #expect(
      AssemblyAITranscriber.chooseTranscript(
        verbatim: "Yeah.", rewrite: style, enhanced: false, instruction: instruction)
        == "Yeah.")
  }
}

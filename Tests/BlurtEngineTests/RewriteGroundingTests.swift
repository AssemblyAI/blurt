import Testing

@testable import BlurtEngine

@Suite("RewriteGrounding")
struct RewriteGroundingTests {
  let style = "No grammatical fixes ever. Just dictate what I say."
  var instruction: String { CleanupInstruction.sendable(appending: style) ?? "" }

  @Test("the instruction read back is not speech, however it is cased, punctuated or padded")
  func echoes() {
    #expect(!RewriteGrounding.isSpeech(style, instruction: instruction))
    #expect(!RewriteGrounding.isSpeech("no grammatical fixes ever — just dictate what I say", instruction: instruction))
    #expect(!RewriteGrounding.isSpeech("Sure. \(style)\nDone.", instruction: instruction))
    #expect(!RewriteGrounding.isSpeech("Return only the cleaned transcript.", instruction: instruction))
    #expect(!RewriteGrounding.isSpeech("Then apply these style preferences from the user", instruction: instruction))
  }

  @Test("nothing said is not speech")
  func nothing() {
    #expect(!RewriteGrounding.isSpeech(".", instruction: instruction))
    #expect(!RewriteGrounding.isSpeech("…, —", instruction: instruction))
    #expect(!RewriteGrounding.isSpeech("", instruction: nil))
  }

  @Test("speech is speech, with or without an instruction to compare against")
  func speech() {
    #expect(RewriteGrounding.isSpeech("Lunch tomorrow works.", instruction: instruction))
    #expect(RewriteGrounding.isSpeech("Lunch tomorrow works.", instruction: nil))
    #expect(RewriteGrounding.isSpeech("Thank you.", instruction: instruction))
    // A short preference sentence inside real speech is not an echo.
    #expect(RewriteGrounding.isSpeech("No emojis, she said, and left.", instruction: "Keep it short. No emojis."))
    #expect(RewriteGrounding.isSpeech("2 pm", instruction: instruction))
  }

  @Test("normalization keeps letters and digits, single-spaced and lowercased")
  func normalization() {
    #expect(RewriteGrounding.normalized("  No, grammatical — FIXES!\n2x ") == "no grammatical fixes 2x")
    #expect(RewriteGrounding.normalized("...") == "")
    #expect(
      RewriteGrounding.sentences(of: "Be brief. No emojis. Write like a quick text to a friend")
        == ["write like a quick text to a friend"])
  }
}

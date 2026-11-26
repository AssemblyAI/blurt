import Testing

@testable import BlurtAssemblyAI
@testable import BlurtEngine

/// What the context is *not* allowed to carry. Every signal below is captured at
/// press time and kept on the machine: the focus fields drive the paste path
/// (the leading separator, the injector's window identity) and the developer-mode
/// log, and the key terms ride their own request field (`KeyTerms`) rather
/// than this one. `text` is the only door to the wire, so this suite is what
/// stands between a captured context and AssemblyAI's servers.
@Suite("STTPrompt scope")
struct STTPromptScopeTests {
  /// The richest context the capture path can produce — every signal populated.
  private let context = TranscriptionContext(
    appName: "Slack",
    priorText: "thanks for",
    windowTitle: "#eng-backend",
    fieldLabel: "Message",
    selectedText: "the draft",
    recentTranscripts: ["Shipping the release notes now."],
    keyTerms: ["Blurt"]
  )

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

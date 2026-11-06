/// Writes what spoken instructions describe ("ok, a Slack reply to Dan: we
/// should have a feature to just speak instructions, keep it casual"), for the
/// Compose From Instructions key (`SelectionSpeechRouting`). Public so a host
/// can stand in its own (the engine's tests and the app's UI tests do).
public protocol MessageComposing: Sendable {
  /// The text `instructions` describe, ready to paste into `app` — the
  /// frontmost app's name, nil when it isn't known.
  func compose(_ instructions: String, for app: String?) async throws -> String
}

/// The production `MessageComposing`: one `POST /v1/chat/completions` to
/// AssemblyAI's LLM Gateway, through `GatewayConnection.send`.
///
/// **The rewrite key's sibling, and like it pasted.** It never sees a
/// dictation's words as text to clean up: the transcript it gets is a
/// hand-back press's spoken instructions (`.handedBack`), which it writes
/// *from*, never pastes. Dictation cleanup stays the dictation API's
/// server-side rewrite (AGENTS.md's settled decisions).
public struct MessageComposer: MessageComposing, GatewayClient {
  /// The rewrite key's model (`SelectionRewriter.model`): writing, where the
  /// larger model earns its latency.
  static let model = SelectionRewriter.model
  /// Room for a long email or a page of notes. A reply that hits it is cut
  /// short and never pasted.
  static let maxTokens = 4_000
  /// The rewrite key's: the same model writing, in one unstreamed reply.
  static let timeout = SelectionRewriter.timeout

  static let instruction = """
    Someone has said out loud what they want written, and your reply is pasted where their \
    cursor is, as if they had typed it themselves. What they said is instructions about the text — \
    who it is for, what it should say, how it should sound — not the text itself. Write the text \
    they describe.

    Never include the instructions themselves ("ok, I'm writing a Slack reply", "make it \
    friendly"). Where they spell out what to say, keep their points and their wording close; \
    where they only sketch it, write it out. Write as them, in the first person, to whoever they \
    are writing to.

    Follow any tone, length, format or language they ask for. Otherwise keep it short and \
    natural, in the language they spoke. Fit it to the app it is going into, named in <app> when \
    known: a chat app such as Slack, Microsoft Teams, Discord or Messages gets a conversational \
    message with no subject line, greeting block or sign-off (in Slack, bold is *single \
    asterisks*); an email gets a greeting and a sign-off; anything else gets plain prose. Use a \
    list only when the content is one, and no Markdown headings.

    The instructions were transcribed from speech and may contain small transcription mistakes. \
    Go with their most likely meaning rather than asking a question back. Never invent names, \
    dates, numbers or commitments they did not give, and never leave a placeholder such as \
    [Name]: write around what is missing.

    Reply with only the text to paste: no preamble such as "Sure" or "Here is", no notes, and no \
    quotation marks around it.
    """

  /// The gateway call, key and transport bound in.
  private let gateway: GatewayConnection

  public init(gateway: GatewayConnection) {
    self.gateway = gateway
  }

  public func compose(_ instructions: String, for app: String?) async throws -> String {
    let reply = try await gateway.send(
      ReadAloudLLM.chat(
        system: Self.instruction, user: Self.prompt(instructions, for: app), maxTokens: Self.maxTokens,
        model: Self.model), timeout: Self.timeout)
    guard !reply.truncated else { throw ReadAloudLLMError.truncated }
    return reply.text
  }

  /// The user turn: the app, when known, then the instructions.
  static func prompt(_ instructions: String, for app: String?) -> String {
    let spoken = "<spoken_instructions>\n\(instructions)\n</spoken_instructions>"
    guard let app, !app.isEmpty else { return spoken }
    return "<app>\(app)</app>\n\n\(spoken)"
  }
}

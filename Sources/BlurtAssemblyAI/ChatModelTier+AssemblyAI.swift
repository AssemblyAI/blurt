import BlurtEngine

/// The LLM Gateway model each of the engine's tiers runs on. The engine asks
/// for a tier (`ChatModelTier`); which model serves it is this package's pick.
extension ChatModelTier {
  /// The gateway's `model` for this tier.
  ///
  /// - `fast`: AssemblyAI's own hosted small model — the docs' quickstart
  ///   model, the cheapest tier on the gateway's `/v1/models` list
  ///   (2026-10-02), served in the US and EU without sending the text to a
  ///   third-party provider, with a 32k-token context.
  /// - `capable`: Gemma 4 (31B), the owner's pick (2026-10-30): $0.14 in /
  ///   $0.40 out per million tokens on the docs' list, with a 256k-token
  ///   context — some twenty hours of speech, so a recording fits whole. It
  ///   follows a `response_format` schema (measured 2026-11-03), which the
  ///   command planner relies on. (The gateway has no free model.)
  var gatewayModel: String {
    switch self {
    case .fast:
      "qwen3.5-4b-32k-fast"

    case .capable:
      "gemma-4-31b"
    }
  }
}

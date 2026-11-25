public import BlurtEngine

extension SpeechServices {
  /// Every speech service on AssemblyAI — streaming TTS and the LLM Gateway —
  /// with the stored key.
  @preconcurrency
  public static func assemblyAI(
    apiKeyProvider: @escaping @Sendable () -> String? = { APIKeyStore.current }
  ) -> SpeechServices {
    SpeechServices(
      synthesizer: AssemblyAISpeechSynthesizer(apiKeyProvider: apiKeyProvider),
      gateway: .assemblyAI(apiKeyProvider: apiKeyProvider)
    )
  }
}

/// The speech-AI services the engine's read-aloud, rewrite, compose and
/// command keys run on, as one value a host hands in. A provider package
/// builds one (`BlurtAssemblyAI`'s `SpeechServices.assemblyAI()`); the engine
/// never names a provider, so another provider's package can supply some or
/// all of these instead.
///
/// Dictation's transcriber is not here: `DictationSession` takes its
/// `TranscriberProtocol` directly, because it is the one service every host
/// needs and the one a host most often wraps (`KeyRejectionReporter`).
public struct SpeechServices: Sendable {
  /// Read-aloud's voice.
  let synthesizer: any SpeechSynthesizing
  /// The LLM every key's client sends through.
  let gateway: GatewayConnection

  public init(synthesizer: any SpeechSynthesizing, gateway: GatewayConnection) {
    self.synthesizer = synthesizer
    self.gateway = gateway
  }
}

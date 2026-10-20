import BlurtEngine

/// The set of engine collaborators `AppCoordinator` composes into a
/// `DictationSession` — exactly the three pipeline seams, since
/// `MicCaptureProtocol` itself carries the mic's side features (the loudness
/// `levels` stream and `warmUp()`, both defaulted for stubs). Bundling them
/// behind one value lets the app swap the whole pipeline for deterministic test
/// doubles (see `DictationComponents.uiTest()`) without `AppCoordinator` knowing
/// which implementation it got — production wiring stays the default.
struct DictationComponents {
  let mic: any MicCaptureProtocol
  let transcriber: any TranscriberProtocol
  let injector: any InjectorProtocol

  /// The real pipeline: a fresh `MicCapture`, the AssemblyAI dictation transcriber,
  /// and the clipboard-paste injector. This is what `AppCoordinator` builds, so
  /// production behavior is unchanged by the test seam existing.
  /// `dictationOrigin` is the signed-in key's dictation host
  /// (`AssemblyAIAccount.dictationOrigin`); production when it holds none.
  /// `onKeyRejected` hears about a dictation refused for its key
  /// (`KeyRejectionReporter`), so the account can renew at once.
  static func production(
    dictationOrigin: DictationOrigin? = nil, onKeyRejected: @escaping @Sendable () -> Void = {}
  ) -> DictationComponents {
    DictationComponents(
      mic: MicCapture(),
      transcriber: KeyRejectionReporter(
        AssemblyAITranscriber(baseURL: {
          dictationOrigin?.current ?? AssemblyAITranscriber.defaultBaseURL
        }),
        onRejected: onKeyRejected),
      injector: KeyInjector()
    )
  }
}

// The key-storage seam (`APIKeyGateway`, with `ProductionAPIKeyStore` and the
// UI tests' `InMemoryAPIKeyStore`) lives in the engine —
// `Sources/BlurtEngine/Config/APIKeyGateway.swift` — so hosts and tests share
// one set of conformances.
//
// The UI-test sentinel API keys live in the shared `UITestIdentifiers`
// (Shared/UITestIdentifiers.swift), alongside the other test-facing constants —
// no longer an unconditionally-compiled enum here.

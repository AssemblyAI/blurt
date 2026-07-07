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

  /// The real pipeline: a fresh `MicCapture`, the AssemblyAI Sync transcriber,
  /// and the clipboard-paste injector. This is what `AppCoordinator` builds, so
  /// production behavior is unchanged by the test seam existing.
  static func production() -> DictationComponents {
    DictationComponents(
      mic: MicCapture(),
      transcriber: AssemblyAITranscriber(),
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

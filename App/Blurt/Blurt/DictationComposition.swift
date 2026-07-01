import BlurtEngine

/// The set of engine collaborators `AppCoordinator` composes into a
/// `DictationSession`, plus the two side channels the coordinator reads off the
/// concrete mic (its loudness `levels` stream and `warmUp`). Bundling them
/// behind one value lets the app swap the whole pipeline for deterministic test
/// doubles (see `DictationComponents.uiTest()`) without `AppCoordinator` knowing
/// which implementation it got — production wiring stays the default.
struct DictationComponents {
  let mic: any MicCaptureProtocol
  let transcriber: any TranscriberProtocol
  let injector: any InjectorProtocol
  /// The mic's loudness feed (0…1) that drives the overlay meter. Kept here
  /// rather than read off `mic` so a stubbed mic can supply its own (or none).
  let levels: AsyncStream<Float>
  /// Pre-opens the mic so the first dictation doesn't pay hardware route
  /// discovery. A closure rather than a protocol method so it stays an
  /// implementation detail of the concrete `MicCapture` (the protocol only
  /// covers `start`/`stop`); test doubles pass a no-op.
  let warmUpMic: @Sendable () async -> Void

  /// The real pipeline: a fresh `MicCapture`, the AssemblyAI Sync transcriber,
  /// and the clipboard-paste injector. This is the default `AppCoordinator`
  /// builds, so production behavior is unchanged by the test seam existing.
  static func production() -> DictationComponents {
    let mic = MicCapture()
    return DictationComponents(
      mic: mic,
      transcriber: AssemblyAITranscriber(),
      injector: KeyInjector(),
      levels: mic.levels,
      warmUpMic: { await mic.warmUp() }
    )
  }
}

/// The narrow slice of `APIKeyStore` that `AppCoordinator` needs, behind a
/// protocol so UI tests can swap an in-memory store and never touch the real
/// Keychain item (writing it would prompt for Keychain access and corrupt the
/// production key's ACL — see the guardrails). Production wraps the static
/// `APIKeyStore`, so the live app reads/writes the Keychain exactly as before.
protocol APIKeyGateway: Sendable {
  func get() -> String?
  @discardableResult func set(_ key: String?) -> Bool
  var hasKey: Bool { get }
}

/// The production `APIKeyGateway`: a thin, stateless forwarder to the
/// Keychain-backed `APIKeyStore`. Stateless, so it's trivially `Sendable`.
struct ProductionAPIKeyStore: APIKeyGateway {
  func get() -> String? { APIKeyStore.get() }
  @discardableResult func set(_ key: String?) -> Bool { APIKeyStore.set(key) }
  var hasKey: Bool { APIKeyStore.hasKey }
}

/// Sentinel API keys the UI-test submit path recognizes to drive the inline
/// error branches (`AppCoordinator.uiTestSubmit`). Defined unconditionally (not
/// behind `#if DEBUG`) because the submit path that reads them is compiled in
/// every configuration; the XCUITest target hard-codes the same string values.
enum UITestKeys {
  static let invalidAPIKey = "uitest-invalid-key"
  static let unreachableAPIKey = "uitest-unreachable-key"
}

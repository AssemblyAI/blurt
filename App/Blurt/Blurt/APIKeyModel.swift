import BlurtEngine
import Observation

/// The app shell's API-key surface, extracted from `AppCoordinator` so the
/// coordinator stays focused on wiring the pipeline to the UI. Owns the storage
/// seam (`APIKeyGateway`), the validate-then-save flow (`APIKeySubmission`), and
/// the observable `hasAPIKey` flag the wizard/Settings react to.
///
/// `@Observable` so views that only care about the key (the API-key step, the
/// wizard's readiness gate) observe *this* directly instead of reaching through
/// the coordinator. The validate-and-never-persist-an-unverified-key rules
/// themselves live in the engine's `APIKeySubmission`, where `swift test` covers
/// them; this type just forwards and mirrors the result into `hasAPIKey`.
@Observable
final class APIKeyModel {
  /// Storage for the API key. Production hits the Keychain via `APIKeyStore`;
  /// UI tests inject an in-memory store so the real key is never touched.
  @ObservationIgnored private let keyStore: any APIKeyGateway
  /// The validate-then-save flow over `keyStore` (engine-owned + unit-tested).
  /// Carries the injected validator: AssemblyAI's real network check in
  /// production, an offline stub under UI testing — both through the one submit
  /// path, so there's no test-only branch here.
  @ObservationIgnored private let submission: APIKeySubmission

  /// Whether an AssemblyAI API key is currently saved. Drives the wizard (which
  /// gates dictation on having a key) and the Settings UI.
  private(set) var hasAPIKey: Bool

  /// `validateKey` defaults to the engine's real AssemblyAI check; UI tests
  /// inject an offline validator so the settings flow needs no network.
  ///
  /// The `hasKey` read below also loads the Keychain memo (`APIKeyStore.get()`),
  /// so every later readiness check on the press→recording latency path is
  /// served from memory instead of paying a cold `SecItemCopyMatching`.
  init(
    keyStore: any APIKeyGateway = ProductionAPIKeyStore(),
    validateKey: @escaping @Sendable (String) async -> APIKeyValidator.Result = {
      await APIKeyValidator().validate($0)
    }
  ) {
    self.keyStore = keyStore
    self.submission = APIKeySubmission(keyStore: keyStore, validate: validateKey)
    self.hasAPIKey = keyStore.hasKey
  }

  /// The key currently stored, read through the gateway. The setup/settings
  /// API-key view reads this (rather than `APIKeyStore` directly) so a UI-test
  /// run sees the injected in-memory store instead of the real Keychain.
  var current: String? { keyStore.get() }

  /// A `@Sendable` snapshot of the readiness gate for `DictationSession`: a press
  /// with no key saved fails fast as `.failed(.apiKeyMissing)` before any capture.
  /// Captures the (Sendable) store, not this main-actor model, so it can cross
  /// into the session's `@Sendable` closure.
  func readinessCheck() -> @Sendable () -> BlurtError? {
    let keyStore = keyStore
    return { keyStore.hasKey ? nil : .apiKeyMissing }
  }

  /// Saves the AssemblyAI API key and refreshes `hasAPIKey` so observers —
  /// including the wizard — react. Returns true only when a non-empty key is
  /// actually readable from Keychain after the write (the engine's
  /// `APIKeySubmission.save` owns that read-back rule).
  @discardableResult
  func save(_ key: String) -> Bool {
    let saved = submission.save(key)
    refreshStatus()
    return saved
  }

  /// Re-reads the Keychain and updates `hasAPIKey`. The flag is otherwise only
  /// set at `init` and after `save`, so it can drift out of sync with what's
  /// actually stored — e.g. an early-launch Keychain read fails (the item's ACL
  /// needs re-approval after a re-sign) before a later read succeeds. Calling this
  /// when the API-key UI appears keeps the readiness gate honest: a key that's
  /// already present flips `hasAPIKey` true, so the wizard advances to the ready
  /// screen instead of stranding the user on a setup step whose only control (a
  /// *changed*-key "Update") is disabled.
  func refreshStatus() {
    let has = keyStore.hasKey
    if has != hasAPIKey { hasAPIKey = has }
  }

  /// Verifies `key` against AssemblyAI and saves it only when AssemblyAI
  /// actively accepts it (`.valid`) — the engine's `APIKeySubmission` owns
  /// (and unit-tests) that never-persist-an-unverified-key rule. Mirrors the
  /// outcome into `hasAPIKey` so the wizard/Settings UI reacts.
  func submit(_ key: String) async -> APIKeySubmission.Outcome {
    let outcome = await submission.submit(key)
    refreshStatus()
    return outcome
  }
}

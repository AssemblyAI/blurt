/// The validate-then-save flow behind the setup/settings screen's Save/Update
/// button. Owned in the engine — rather than in the app coordinator — so its
/// central invariant is unit-tested: **an unverified key never persists.** A key
/// is written only after AssemblyAI actively accepts it (`.valid`); a rejected
/// key (`.invalid`) or an unreachable server (`.unreachable`) leaves the stored
/// key untouched, and a write that doesn't survive a read-back is surfaced as
/// `.saveFailed` instead of silently claiming success.
public struct APIKeySubmission: Sendable {
  /// Outcome of a submission attempt. `.invalid`/`.unreachable` mirror
  /// `APIKeyValidator.Result` (nothing was saved); `.saveFailed` means the key
  /// validated but couldn't be written to (or read back from) storage.
  public enum Outcome: Sendable, Equatable {
    case valid
    case invalid
    case unreachable
    case saveFailed
  }

  private let keyStore: any APIKeyGateway
  private let validate: @Sendable (String) async -> APIKeyValidator.Result

  public init(keyStore: any APIKeyGateway, validator: APIKeyValidator = APIKeyValidator()) {
    self.init(keyStore: keyStore, validate: { await validator.validate($0) })
  }

  /// Seam that injects the validation outcome directly, bypassing HTTP: tests use
  /// it to cover the outcome mapping and the never-save-unverified invariant, and
  /// the app injects an offline validator under UI testing (so the settings flow
  /// runs without a network) — both through the one real submit path.
  public init(
    keyStore: any APIKeyGateway,
    validate: @escaping @Sendable (String) async -> APIKeyValidator.Result
  ) {
    self.keyStore = keyStore
    self.validate = validate
  }

  /// Writes `key` to the store. Returns true only when a non-empty key is
  /// actually readable back after the write — a write that "succeeds" but
  /// leaves no key stored (e.g. a whitespace-only key, which the gateway
  /// treats as a delete) is a failure to save a key.
  @discardableResult
  public func save(_ key: String) -> Bool {
    keyStore.set(key) && keyStore.hasKey
  }

  /// Verifies `key` against AssemblyAI and saves it only when AssemblyAI
  /// actively accepts it. On `.invalid`/`.unreachable` the caller surfaces an
  /// inline error and the user retries — the stored key is left untouched.
  public func submit(_ key: String) async -> Outcome {
    switch await validate(key) {
    case .valid:
      return save(key) ? .valid : .saveFailed
    case .invalid:
      return .invalid
    case .unreachable:
      return .unreachable
    }
  }
}

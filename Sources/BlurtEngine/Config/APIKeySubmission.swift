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

  /// How a failed submission should be reported. The *classification* is the
  /// case: a problem the user can fix by editing the field belongs inline, while
  /// a system fault retyping can't touch belongs in an alert — the convention
  /// that makes the inline cases legible as "retype this" rather than "something
  /// broke". Owned here, next to the outcomes it classifies, for the same reason
  /// as `PipelinePhase.setupBlocker`: the shell renders the engine's single
  /// judgement instead of re-deriving it, so adding an `Outcome` case can't
  /// silently ship with the wrong severity.
  public enum FailureReport: Sendable, Equatable {
    /// Recoverable — show `message` beside the field and let the user retry.
    case inline(message: String)
    /// A genuine fault (the Keychain write itself failed). Retyping the key
    /// can't fix it, so present it as an alert.
    case alert(title: String, message: String)
  }

  private let keyStore: any APIKeyGateway
  private let validate: @Sendable (String) async -> APIKeyValidator.Result

  /// The validation outcome is injected as a closure: production passes
  /// `APIKeyValidator`'s real AssemblyAI check (see `APIKeyModel`'s default),
  /// UI testing passes an offline stub (so the settings flow runs without a
  /// network), and tests inject outcomes directly to cover the mapping and the
  /// never-save-unverified invariant — all through the one real submit path.
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
    keyStore.save(key) && keyStore.hasKey
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

extension APIKeySubmission.Outcome {
  /// How to report this outcome, or `nil` for `.valid` — which has nothing to
  /// report: the key verified and stored, so the sheet just closes.
  public var failureReport: APIKeySubmission.FailureReport? {
    switch self {
    case .valid:
      nil
    case .invalid:
      .inline(message: "AssemblyAI rejected that key. Double-check it and try again.")
    case .unreachable:
      .inline(message: "Couldn't reach AssemblyAI. Check your connection and try again.")
    case .saveFailed:
      .alert(
        title: "Couldn’t Save Your Key",
        message:
          "Blurt couldn’t write the key to your macOS Keychain. Check Keychain access and try again."
      )
    }
  }
}

import Foundation
import Synchronization

/// Keychain-backed storage for the AssemblyAI API key.
///
/// Used both by `AssemblyAITranscriber` (to authenticate requests) and by the
/// app's setup UI (to read/write the key). The key is stored as a generic
/// password in the user's default keychain; Blurt runs unsandboxed, so no
/// keychain-access-group entitlement is required.
public enum APIKeyStore {
  /// Where users go to create / copy their AssemblyAI API key.
  public static let dashboardURL = URL(staticString: "https://www.assemblyai.com/dashboard/api-keys")

  /// The production keychain item. The service is the (lowercase) bundle id, to
  /// match the macOS convention. Tests exercise `KeychainStore` directly with an
  /// isolated service/account so they never touch this real key.
  static let store = KeychainStore(service: BlurtIdentity.subsystem, account: "AssemblyAIAPIKey")

  /// In-memory memo of the Keychain read. Every hot path funnels through `get()`:
  /// the readiness check on *every* hotkey press (`APIKeyGateway.hasKey`, which
  /// runs at the top of `DictationSession.performPress` — before `mic.start()`,
  /// so it sat directly in the press→recording latency) and the transcriber's
  /// per-dictation `apiKeyProvider`. Each was a synchronous `SecItemCopyMatching`.
  /// Blurt is the only writer of this item, so memoizing is safe as long as
  /// `set()` refreshes the memo. `.unloaded` distinguishes "never read" from a
  /// genuinely stored `nil` (no key saved). The `Mutex` keeps this thread-safe
  /// across the main-actor readiness check and the off-actor transcriber read.
  private static let cache = Mutex<Cached>(.unloaded)
  private enum Cached {
    case unloaded
    case loaded(String?)
  }

  /// The stored key, or `nil` if none has been saved (or it's empty). Served from
  /// the in-memory memo after the first read; see `cache`.
  public static func get() -> String? {
    cache.withLock { state in
      if case .loaded(let value) = state { return value }
      let value = store.get()
      state = .loaded(value)
      return value
    }
  }

  /// Stores `key` (trimmed). Passing `nil` or an empty/whitespace string
  /// deletes the stored key. Returns `true` on success.
  @discardableResult
  public static func set(_ key: String?) -> Bool {
    let ok = store.set(key)
    // Refresh the memo from the store rather than caching `key` verbatim: `set`
    // trims/normalizes (and maps empty → deleted), so a re-read reflects exactly
    // what `get()` would now return, and a failed write leaves no stale value.
    let stored = store.get()
    cache.withLock { $0 = .loaded(stored) }
    return ok
  }

  // "Has a key?" lives on the injectable seam: `APIKeyGateway.hasKey`
  // (`ProductionAPIKeyStore` wraps this store), so the derivation exists once.
}

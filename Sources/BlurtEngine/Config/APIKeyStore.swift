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
      switch store.read() {
      case .value(let key):
        state = .loaded(key)
        return key
      case .absent:
        state = .loaded(nil)
        return nil
      case .unavailable:
        // Deliberately NOT memoized. A transient read failure — a locked login
        // keychain, or the user denying the item's ACL prompt (which
        // re-signing the app forces) — would otherwise pin "no API key" for the
        // rest of the process: the wizard claims setup is incomplete and every
        // press fails `.apiKeyMissing` with no way back short of a relaunch or
        // retyping the key. Leaving the cache `.unloaded` means the next press
        // retries the Keychain, which is how this self-healed before the memo.
        return nil
      }
    }
  }

  /// Stores `key` (trimmed). Passing `nil` or an empty/whitespace string
  /// deletes the stored key. Returns `true` on success.
  @discardableResult
  public static func set(_ key: String?) -> Bool {
    // The write, the read-back, and the memo update all happen under one lock, so
    // two overlapping writers can't interleave into a memo that disagrees with the
    // Keychain (write A, write B, memo B, memo A would leave `hasKey` true for a
    // key the Keychain no longer holds — a 401 the user can't explain until
    // relaunch). `store` does not take this lock, so there's no reentrancy.
    cache.withLock { state in
      let ok = store.set(key)
      // Re-read rather than caching `key` verbatim: `set` trims/normalizes (and
      // maps empty → deleted), so a read-back reflects exactly what `get()` would
      // now return, and a failed write leaves no stale value. An unreadable
      // Keychain leaves the memo unloaded so the next `get()` retries.
      switch store.read() {
      case .value(let stored): state = .loaded(stored)
      case .absent: state = .loaded(nil)
      case .unavailable: state = .unloaded
      }
      return ok
    }
  }

  // "Has a key?" lives on the injectable seam: `APIKeyGateway.hasKey`
  // (`ProductionAPIKeyStore` wraps this store), so the derivation exists once.
}

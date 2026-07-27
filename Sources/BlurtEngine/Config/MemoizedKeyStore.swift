import Synchronization

/// The in-memory memo in front of the API key's storage, plus the write path that
/// keeps the two agreeing.
///
/// Extracted from `APIKeyStore`'s statics so these rules are testable at all. With
/// the keychain item *and* the memo both process-global, neither of the two bugs
/// this type encodes could be exercised without writing the real production key —
/// which tests must never do (it prompts for keychain access and corrupts the live
/// item's ACL). Both bugs were real, and both are silent:
///
/// 1. Memoizing an *unreadable* read pinned "no API key" for the whole process.
/// 2. A write whose memo update wasn't atomic with it could leave `hasKey` true for
///    a key the storage no longer held.
///
/// `read`/`write` are injected closures rather than a protocol, matching how
/// `KeyInjector` and `APIKeySubmission` take their side effects — a test hands over
/// a double that returns `.unavailable` on demand and counts how often storage was
/// consulted.
final class MemoizedKeyStore: Sendable {
  /// `.unloaded` distinguishes "never read" from a genuinely stored `nil` (no key
  /// saved) — without it, a cached "no key" and an unread memo look identical.
  private enum Cached {
    case unloaded
    case loaded(String?)
  }

  private let read: @Sendable () -> KeychainStore.ReadResult
  private let write: @Sendable (String?) -> Bool

  /// The `Mutex` keeps the memo thread-safe across the main-actor readiness check
  /// and the off-actor transcriber read, and is what makes this type `Sendable`
  /// without an `@unchecked` escape hatch.
  private let cache = Mutex<Cached>(.unloaded)

  init(
    read: @escaping @Sendable () -> KeychainStore.ReadResult,
    write: @escaping @Sendable (String?) -> Bool
  ) {
    self.read = read
    self.write = write
  }

  /// Memoizes over a keychain item.
  convenience init(keychain: KeychainStore) {
    self.init(read: { keychain.read() }, write: { keychain.write($0) })
  }

  /// The stored key, or `nil` if none has been saved (or it's empty).
  ///
  /// Served from the memo after the first successful read. Every hot path funnels
  /// through here: the readiness check on *every* hotkey press
  /// (`APIKeyGateway.hasKey`, which runs at the top of
  /// `DictationSession.performPress` — before `mic.start()`, so it sat directly in
  /// the press→recording latency) and the transcriber's per-dictation
  /// `apiKeyProvider`. Each was otherwise a synchronous `SecItemCopyMatching`.
  /// Blurt is the only writer of the item, so memoizing is safe as long as `save`
  /// refreshes the memo.
  var current: String? {
    cache.withLock { state in
      if case .loaded(let value) = state { return value }
      switch read() {
      case .value(let key):
        state = .loaded(key)
        return key
      case .absent:
        state = .loaded(nil)
        return nil
      case .unavailable:
        // Deliberately NOT memoized. A transient read failure — a locked login
        // keychain, or the user denying the item's ACL prompt (which re-signing the
        // app forces) — would otherwise pin "no API key" for the rest of the
        // process: the wizard claims setup is incomplete and every press fails
        // `.apiKeyMissing` with no way back short of a relaunch or retyping the key.
        // Leaving the memo `.unloaded` means the next read retries storage, which is
        // how this self-healed before the memo existed.
        return nil
      }
    }
  }

  /// Stores `key`. Passing `nil` or an empty/whitespace string deletes it.
  /// Returns whether the write succeeded.
  @discardableResult
  func save(_ key: String?) -> Bool {
    // The write, the read-back, and the memo update all happen under one lock, so
    // two overlapping writers can't interleave into a memo that disagrees with
    // storage (write A, write B, memo B, memo A would leave `hasKey` true for a key
    // storage no longer holds — a 401 the user can't explain until relaunch).
    // Neither injected closure takes this lock, so there's no reentrancy.
    cache.withLock { state in
      let ok = write(key)
      // Re-read rather than memoizing `key` verbatim: the storage layer
      // trims/normalizes (and maps empty → deleted), so a read-back reflects exactly
      // what `current` would now return, and a failed write leaves no stale value.
      // Unreadable storage leaves the memo unloaded so the next read retries.
      switch read() {
      case .value(let stored): state = .loaded(stored)
      case .absent: state = .loaded(nil)
      case .unavailable: state = .unloaded
      }
      return ok
    }
  }
}

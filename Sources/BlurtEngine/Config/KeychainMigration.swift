/// One-shot move of a generic-password item from the service name it lived
/// under before the rename (`BlurtIdentity.legacyKeychainService`) to the
/// current one (`BlurtIdentity.keychainService`).
///
/// Runs lazily inside `APIKeyStore`'s read closure rather than as a startup
/// hook: every consumer — the wizard's readiness check, the hotkey press, the
/// transcriber — already funnels through `MemoizedKeyStore.current`, so the
/// first read after an upgrade migrates the key and later reads hit the memo.
enum KeychainMigration {
  /// Reads `current`, falling back to `legacy` when nothing is stored under the
  /// new service. A legacy value is copied to `current` before the old item is
  /// deleted — in that order, so a failed write can't lose the only copy.
  static func read(
    current: KeychainStore, legacy: KeychainStore
  ) -> KeychainStore.ReadResult {
    let result = current.read()
    guard case .absent = result else { return result }

    switch legacy.read() {
    case .value(let key):
      if current.write(key) { legacy.write(nil) }
      return .value(key)
    case .absent:
      return .absent
    case .unavailable(let status):
      // Whether a legacy key exists is unknown, so report the read as failed:
      // returning `.absent` here would let `MemoizedKeyStore` durably memoize
      // "no API key" before the migration ever saw the old item.
      return .unavailable(status)
    }
  }
}

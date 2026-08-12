/// Reads and writes the current keychain item, adopting any value left behind
/// under the service Blurt used to store it as.
///
/// The API key was originally stored under `BlurtIdentity.subsystem`
/// ("dev.alex.blurt"), which is the string Keychain Access shows as the item's
/// name. The service is now the product name, and that rename has to be
/// invisible to everyone who already saved a key: the first read that finds
/// nothing under the current service copies the legacy value across and deletes
/// the old item, so nobody is silently logged out and the stale entry doesn't
/// linger.
struct MigratingKeychainStore: Sendable {
  let current: KeychainStore
  let legacy: KeychainStore

  /// Reads the current item, falling back to the legacy one exactly once — the
  /// adoption deletes the legacy item, so later reads are a single lookup.
  func read() -> KeychainStore.ReadResult {
    let result = current.read()
    // Only a durable "nothing saved here" is worth a legacy lookup. `.unavailable`
    // (locked keychain, denied ACL prompt) says nothing about whether the current
    // item exists, so falling back on it could adopt a stale key over a live one.
    guard case .absent = result else { return result }

    switch legacy.read() {
    case .value(let key):
      // Keep the legacy item when the copy fails so the next launch retries the
      // migration; either way the caller gets the key it asked for.
      if current.write(key) { legacy.write(nil) }
      return .value(key)
    case .absent:
      return .absent
    case .unavailable(let status):
      // Don't answer `.absent` while an unreadable legacy item may still hold the
      // key: `MemoizedKeyStore` memoizes that answer and would pin "no API key"
      // for the rest of the process.
      return .unavailable(status)
    }
  }

  /// Writes through to the current item and, on success, clears the legacy one:
  /// a surviving legacy item would let `read()` resurrect a key the user just
  /// deleted. Clearing it only after a successful write keeps a failed write from
  /// destroying the one copy that's left.
  @discardableResult
  func write(_ value: String?) -> Bool {
    let didWrite = current.write(value)
    if didWrite { legacy.write(nil) }
    return didWrite
  }
}

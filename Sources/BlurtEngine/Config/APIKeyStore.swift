import Foundation

/// Keychain-backed storage for the AssemblyAI API key.
///
/// Used both by `AssemblyAITranscriber` (to authenticate requests) and by the
/// app's setup UI (to read/write the key). The key is stored as a generic
/// password in the user's default keychain; Blurt runs unsandboxed, so no
/// keychain-access-group entitlement is required.
///
/// A thin static facade: the memo-and-write rules live in `MemoizedKeyStore`, which
/// takes its storage as closures so those rules are unit-tested against a double
/// instead of the real keychain item.
public enum APIKeyStore {
  /// Where users go to create / copy their AssemblyAI API key.
  public static let dashboardURL = URL(staticString: "https://www.assemblyai.com/dashboard/api-keys")

  /// The production keychain item. Tests never reach this — they build their
  /// own `MemoizedKeyStore`, and `KeychainStoreTests` uses an isolated
  /// service/account — so the real key is never read or written by a test run.
  private static let keychain = KeychainStore(
    service: BlurtIdentity.keychainService, account: "AssemblyAIAPIKey")

  /// The item's home before the service rename. Read only by the migration
  /// below, and written only to delete a key that has moved to `keychain`.
  private static let legacyKeychain = KeychainStore(
    service: BlurtIdentity.legacyKeychainService, account: "AssemblyAIAPIKey")

  /// The memoized item. The read migrates a pre-rename key on first touch (see
  /// `KeychainMigration`); writes always target the current service.
  private static let memo = MemoizedKeyStore(
    read: { KeychainMigration.read(current: keychain, legacy: legacyKeychain) },
    write: { keychain.write($0) })

  /// The stored key, or `nil` if none has been saved (or it's empty).
  public static var current: String? { memo.current }

  /// Stores `key` (trimmed). Passing `nil` or an empty/whitespace string
  /// deletes the stored key. Returns `true` on success.
  @discardableResult
  public static func save(_ key: String?) -> Bool { memo.save(key) }

  // "Has a key?" lives on the injectable seam: `APIKeyGateway.hasKey`
  // (`ProductionAPIKeyStore` wraps this store), so the derivation exists once.
}

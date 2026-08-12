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

  /// The account every Blurt install stores the key under; it survived the
  /// service rename, so it's shared by the current and legacy items.
  private static let account = "AssemblyAIAPIKey"

  /// The production keychain item, memoized. The service is the product name —
  /// Keychain Access shows it as the item's name — and `MigratingKeychainStore`
  /// carries over a key still saved under the old reverse-DNS service. Tests never
  /// reach this: they build their own `MemoizedKeyStore`, and the keychain suites
  /// use isolated services/accounts, so the real key is never read or written by a
  /// test run.
  private static let memo = MemoizedKeyStore(
    keychain: MigratingKeychainStore(
      current: KeychainStore(service: BlurtIdentity.keychainService, account: account),
      legacy: KeychainStore(service: BlurtIdentity.legacyKeychainService, account: account)))

  /// The stored key, or `nil` if none has been saved (or it's empty).
  public static var current: String? { memo.current }

  /// Stores `key` (trimmed). Passing `nil` or an empty/whitespace string
  /// deletes the stored key. Returns `true` on success.
  @discardableResult
  public static func save(_ key: String?) -> Bool { memo.save(key) }

  // "Has a key?" lives on the injectable seam: `APIKeyGateway.hasKey`
  // (`ProductionAPIKeyStore` wraps this store), so the derivation exists once.
}

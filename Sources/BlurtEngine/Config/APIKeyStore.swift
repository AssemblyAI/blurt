import Foundation

/// Keychain-backed storage for the AssemblyAI API key.
///
/// Used both by `AssemblyAITranscriber` (to authenticate requests) and by the
/// app's setup UI (to read/write the key). The key is stored as a generic
/// password in the user's default keychain; Blurt runs unsandboxed, so no
/// keychain-access-group entitlement is required.
public enum APIKeyStore {
  /// Where users go to create / copy their AssemblyAI API key.
  public static let dashboardURL = URL(string: "https://www.assemblyai.com/dashboard/api-keys")!

  /// The production keychain item. The service is the (lowercase) bundle id, to
  /// match the macOS convention. Tests exercise `KeychainStore` directly with an
  /// isolated service/account so they never touch this real key.
  static let store = KeychainStore(service: BlurtIdentity.subsystem, account: "AssemblyAIAPIKey")

  /// The stored key, or `nil` if none has been saved (or it's empty).
  public static func get() -> String? { store.get() }

  /// Stores `key` (trimmed). Passing `nil` or an empty/whitespace string
  /// deletes the stored key. Returns `true` on success.
  @discardableResult
  public static func set(_ key: String?) -> Bool { store.set(key) }

  /// Whether a non-empty key is currently stored.
  public static var hasKey: Bool { Self.get() != nil }
}

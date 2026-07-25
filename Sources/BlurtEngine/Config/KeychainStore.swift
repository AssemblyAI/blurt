import Foundation
import Security

/// Reads and writes a single string as a generic-password keychain item.
/// `service`/`account` are injectable so tests can use an isolated namespace.
struct KeychainStore: Sendable {
  let service: String
  let account: String

  /// Why a read produced no value. Collapsing these to a bare `nil` is unsafe for
  /// any caller that *memoizes* the answer: `errSecItemNotFound` is a durable fact
  /// ("nothing saved"), while a locked keychain or a denied ACL prompt is a
  /// transient failure that must not be cached as "nothing saved".
  enum ReadResult: Sendable, Equatable {
    /// The item is absent, or present but empty / not valid UTF-8 — a durable
    /// "there is no usable value here".
    case absent
    /// The stored value.
    case value(String)
    /// The read itself failed, so whether a value exists is unknown. Seen when the
    /// login keychain is locked, when the user denies the "wants to use your
    /// confidential information" ACL prompt, or when the item's ACL needs
    /// re-approval after the app is re-signed.
    case unavailable(OSStatus)
  }

  /// Reads the item, distinguishing "nothing saved" from "couldn't read it".
  func read() -> ReadResult {
    var query = baseQuery()
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    switch status {
    case errSecSuccess:
      guard let data = item as? Data,
        let key = String(data: data, encoding: .utf8),
        !key.isEmpty
      else { return .absent }
      return .value(key)
    case errSecItemNotFound:
      return .absent
    default:
      return .unavailable(status)
    }
  }


  /// Stores `value` (trimmed). Passing `nil` or an empty/whitespace string
  /// deletes the stored value. Returns `true` on success.
  @discardableResult
  func set(_ value: String?) -> Bool {
    guard let trimmed = value.trimmedNonEmpty() else {
      let status = SecItemDelete(baseQuery() as CFDictionary)
      return status == errSecSuccess || status == errSecItemNotFound
    }

    let data = Data(trimmed.utf8)
    switch update(data) {
    case errSecSuccess: return true
    case errSecItemNotFound: break
    default: return false
    }

    var addQuery = baseQuery()
    addQuery[kSecValueData as String] = data
    switch SecItemAdd(addQuery as CFDictionary, nil) {
    case errSecSuccess: return true
    // Update-then-add is not atomic: a concurrent writer can insert the item
    // between our two calls. The item exists now, so store our value with a
    // second update instead of reporting a failed save for a key that's there.
    case errSecDuplicateItem: return update(data) == errSecSuccess
    default: return false
    }
  }

  /// The single definition of the value-update write, shared by the first-try
  /// update and the lost-the-add-race retry so their attributes can't drift.
  private func update(_ data: Data) -> OSStatus {
    SecItemUpdate(
      baseQuery() as CFDictionary,
      [kSecValueData as String: data] as CFDictionary
    )
  }

  private func baseQuery() -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
  }
}

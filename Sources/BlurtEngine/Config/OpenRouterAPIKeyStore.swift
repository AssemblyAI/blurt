public enum OpenRouterAPIKeyStore {
  private static let memo = MemoizedKeyStore(
    keychain: KeychainStore(
      service: HostIdentity.current.keychainService,
      account: "OpenRouterAPIKey"))

  public static var current: String? { memo.current }

  @discardableResult
  public static func save(_ key: String?) -> Bool { memo.save(key) }
}

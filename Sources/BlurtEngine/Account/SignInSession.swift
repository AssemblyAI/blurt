import Foundation

/// What Blurt keeps about a "Sign in with AssemblyAI" connection, beside the API
/// key itself (which lives in the ordinary key item, so every reader of the key
/// works unchanged whether it was pasted or signed in for).
public struct SignInSession: Codable, Sendable, Equatable {
  /// Mints fresh access tokens. Rotated by the server on some refreshes, so the
  /// latest one is always written back.
  public var refreshToken: String
  /// Who signed in, for the account row. Nil when the ID token didn't say.
  public var email: String?
  /// When the connection's key stops working, as the exchange reported it.
  public var keyExpiresAt: Date?
  /// The last successful refresh and exchange.
  public var renewedAt: Date

  public init(refreshToken: String, email: String?, keyExpiresAt: Date?, renewedAt: Date) {
    self.refreshToken = refreshToken
    self.email = email
    self.keyExpiresAt = keyExpiresAt
    self.renewedAt = renewedAt
  }

  /// At most one renewal a day. Each one also slides the refresh token's
  /// lifetime, so a Mac that opens Blurt now and then stays signed in.
  public static let renewalInterval: TimeInterval = 24 * 60 * 60
  /// Renew this far ahead of the key's expiry, so the next key is in place
  /// before the old one stops working mid-dictation.
  public static let expiryMargin: TimeInterval = 2 * 24 * 60 * 60

  /// Whether a renewal check should refresh and exchange now: a day since the last renewal, the key close to expiring, or no key
  /// stored at all.
  public func isRenewalDue(now: Date, hasKey: Bool) -> Bool {
    if !hasKey { return true }
    if now.timeIntervalSince(renewedAt) >= Self.renewalInterval { return true }
    if let keyExpiresAt, keyExpiresAt.timeIntervalSince(now) <= Self.expiryMargin { return true }
    return false
  }
}

/// Keychain storage for the `SignInSession`, as JSON in its own item next to the
/// API key. `read`/`write` are closures, the way `MemoizedKeyStore` takes its
/// storage, so tests hand over a double instead of the real item.
public struct SignInStore: Sendable {
  /// A read that keeps "nothing stored" apart from "couldn't read it" (a locked
  /// Keychain, an ACL prompt pending after a re-sign) — the distinction
  /// `KeychainStore.ReadResult` exists for. Treating the second as the first
  /// would show a signed-in Mac as signed out, and let Sign Out delete the key
  /// without ending the connection.
  public enum Load: Sendable, Equatable {
    case none
    case session(SignInSession)
    case unavailable
  }

  private let read: @Sendable () -> KeychainStore.ReadResult
  private let write: @Sendable (String?) -> Bool

  init(read: @escaping @Sendable () -> KeychainStore.ReadResult, write: @escaping @Sendable (String?) -> Bool) {
    self.read = read
    self.write = write
  }

  /// The production item, in the host's Keychain service.
  public static let production: SignInStore = {
    let keychain = KeychainStore(service: HostIdentity.current.keychainService, account: "AssemblyAISignIn")
    return SignInStore(read: { keychain.read() }, write: { keychain.write($0) })
  }()

  /// An in-memory store for tests and UI-test runs.
  public static func inMemory() -> SignInStore {
    let box = InMemoryAPIKeyStore()
    return SignInStore(
      read: { box.current.map { .value($0) } ?? .absent },
      write: { box.save($0) })
  }

  public var load: Load {
    switch read() {
    case .absent: return .none
    case .unavailable: return .unavailable
    case .value(let json):
      // An item that doesn't decode is as good as none: nothing in it can be
      // refreshed.
      guard let session = try? JSONDecoder.signIn.decode(SignInSession.self, from: Data(json.utf8))
      else { return .none }
      return .session(session)
    }
  }

  /// Stores `session`, or deletes the item for nil.
  @discardableResult
  public func save(_ session: SignInSession?) -> Bool {
    guard let session else { return write(nil) }
    guard let data = try? JSONEncoder.signIn.encode(session), let json = String(bytes: data, encoding: .utf8)
    else { return false }
    return write(json)
  }
}

extension JSONEncoder {
  fileprivate static var signIn: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }
}

extension JSONDecoder {
  fileprivate static var signIn: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}

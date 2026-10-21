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
  /// When to renew: from when the exchange mints the next key, as it reported
  /// it (`api_key_rotates_at`). Nil from a server that doesn't say, or a
  /// session saved before it did.
  public var keyRotatesAt: Date?
  /// The last successful refresh and exchange.
  public var renewedAt: Date

  public init(
    refreshToken: String, email: String?, keyExpiresAt: Date?, keyRotatesAt: Date? = nil, renewedAt: Date
  ) {
    self.refreshToken = refreshToken
    self.email = email
    self.keyExpiresAt = keyExpiresAt
    self.keyRotatesAt = keyRotatesAt
    self.renewedAt = renewedAt
  }

  /// Without `keyRotatesAt`, renew this far ahead of the key's expiry (the
  /// server's usual rotation window), so the next key is in place before the
  /// old one stops working mid-dictation. One renewal per key is all the
  /// refresh token needs: its sliding lifetime (three months) dwarfs a key's
  /// (two weeks).
  public static let expiryMargin: TimeInterval = 2 * 24 * 60 * 60
  /// When the exchange didn't say when the key expires: renew this long after
  /// the last renewal instead.
  public static let unknownExpiryInterval: TimeInterval = 24 * 60 * 60

  /// When the next renewal is due: when the server said the key rotates, else
  /// `expiryMargin` before it expires.
  public var renewalDue: Date {
    keyRotatesAt
      ?? keyExpiresAt.map { $0.addingTimeInterval(-Self.expiryMargin) }
      ?? renewedAt.addingTimeInterval(Self.unknownExpiryInterval)
  }

  /// After a renewal that brought back a key still due for renewal (a server
  /// that didn't rotate it early): push the next renewal to the key's expiry,
  /// when any server rotates, or once it has expired, a day out, rather than
  /// asking again every minute. A dictation the key fails meanwhile still
  /// renews at once (`AssemblyAIAccount.keyWasRejected`).
  mutating func deferRenewalIfStillDue(now: Date) {
    guard renewalDue <= now else { return }
    if let keyExpiresAt, keyExpiresAt > now {
      keyRotatesAt = keyExpiresAt
    } else {
      keyRotatesAt = now.addingTimeInterval(Self.unknownExpiryInterval)
    }
  }

  /// Whether a renewal should refresh and exchange now: it's due, or no key is
  /// stored at all.
  public func isRenewalDue(now: Date, hasKey: Bool) -> Bool {
    !hasKey || now >= renewalDue
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
